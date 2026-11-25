# erXos: architecture

> In erXos, Erlang's process is the operating system's process: one process
> space, one message system and one view of identity, supervision and
> inspection span every runtime, and one CPU authority gives each runtime
> the time its grant allows.

erXos is a cross-platform operating system built around running Erlang
applications, on AArch64 first. Its kernel is a capability microkernel of
its own, written in C17 on the design and know-how of L4Re's Fiasco. The
kernel knows threads, groups of threads, memory, capabilities and
interrupts, and nothing of Erlang. It allocates CPU time to native threads
and to **runtime groups**, and each runtime, ERTS first, schedules its own
lightweight processes within its group's **grant**, switching between them
without entering the kernel. Every runtime runs in user mode, including
the one that runs the system services, which are mostly Erlang. Across
runtimes, a pid names its owner domain by construction, every signal
between domains travels on a **connection** the system domain made and is
checked by the receiving runtime's own **funnel**, and process links,
monitors and exits keep Erlang's semantics, so the whole machine is one
Erlang system. Everything is inspectable from an Erlang shell on the
serial console or from the development host, down to kernel objects and
the line of source a process is executing. Until erXos's kernel is
written, a near-stock Fiasco stands in for it behind the same interface,
and the first release ships on it ([design-fiasco.md](design-fiasco.md)).

This document holds the system's shape, the decisions that constrain more
than one subsystem with their reasons, and the map of the subsystem
designs. The decisions every reader needs are in
[Decisions](#decisions); the properties the system holds by construction
are in [Invariants](#invariants) and [Correct by construction in
code](#correct-by-construction-in-code).

## Document map

Start with [overview.md](overview.md) for a compact introduction. The
subsystem designs below define their contracts within this architecture;
the architecture and platform bindings supply the hardware-specific
details. The roadmap owns sequencing and acceptance gates. Open defects
belong in [TODO.md](../TODO.md); unadopted alternatives in
[todo-simplification.md](todo-simplification.md). Research records supply
evidence, not design contracts.

| Document | Role |
| --- | --- |
| [overview.md](overview.md) | a reader's introduction to the design |
| [book/](book/README.md) | *erXos: An Operating System in Erlang*, a book-length account that cites the design documents and decides nothing |
| [design-book-site.md](design-book-site.md) | the book on the website: Markdown rendered to static pages at build time, diagrams drawn from the book's Mermaid, typography and fonts |
| this document | the architecture and every decision that constrains more than one subsystem |
| [design-kernel.md](design-kernel.md) | erXos's kernel: objects, capabilities, budgets, memory, spaces, threads, IPC, interrupts, boot, the ABI and its L4 lineage |
| [design-fiasco.md](design-fiasco.md) | erXos on Fiasco, the kernel of Phase 1 and of the first release: the backend, the call table, the downsides against erXos's kernel, the release build |
| [design-stopgap.md](design-stopgap.md) | littlefs in the storage domain and its release contract |
| [design-arch-aarch64.md](design-arch-aarch64.md) | the AArch64 binding of the kernel's port contract |
| [design-platforms.md](design-platforms.md) | the platform binding: QEMU `virt`, the Raspberry Pi 4 and 5 |
| [design-scheduler.md](design-scheduler.md) | the first level: groups, grants, urgency, park and wake, service work, the runtime contract |
| [design-runtime.md](design-runtime.md) | the runtimes in user mode: ERTS recombined, the runtime images, the device NIF, the C library seam, `liberx` |
| [design-shared-devices.md](design-shared-devices.md) | devices that share a register page or an interrupt line |
| [design-device-dma.md](design-device-dma.md) | DMA by devices that are not cache-coherent, and the descriptor forms the device NIF drives |
| [design-device-tree.md](design-device-tree.md) | the firmware's device tree in the root task |
| [design-pcie.md](design-pcie.md) | PCIe: the PCIe domain's enumerator, BAR placement, bus mastering and interrupts |
| [design-rp1.md](design-rp1.md) | RP1, the Raspberry Pi 5's I/O controller: its parts, interrupts, Ethernet and USB hosts |
| [design-header-io.md](design-header-io.md) | the Raspberry Pi 4's 40-pin header: GPIO, I2C, SPI and PWM |
| [design-pinctrl.md](design-pinctrl.md) | pin control: a board's pin table, the pin driver, a device's named pin states and plain GPIO |
| [design-board-sensors.md](design-board-sensors.md) | the Raspberry Pi 4's firmware readings and `/proc/sensors` |
| [design-shared-code.md](design-shared-code.md) | one image of shared loaded code mapped into every domain |
| [design-programs.md](design-programs.md) | native programs and the POSIX-lite personality |
| [design-pipes.md](design-pipes.md) | pipes in user space |
| [design-domains.md](design-domains.md) | domains, the pid space, connections, exports, the funnel, frames, facets |
| [design-system.md](design-system.md) | the root task, the system manifest, the domain library, devices and drivers, the system services, the vault |
| [design-files.md](design-files.md) | namespaces, the file protocol (9P2000.L), file servers, shared mappings |
| [design-tmp.md](design-tmp.md) | the RAM file system at `/tmp` |
| [design-storage.md](design-storage.md) | partitions, the boot image, system partitions, EROFS, FAT, A/B updates |
| [design-f2fs.md](design-f2fs.md) | erXos's F2FS, the main read-write file system, in Erlang |
| [design-drives.md](design-drives.md) | drives: every medium but the boot medium served whole, its table and its volumes' formats read in the media domain, FAT and EROFS volumes at `/media`, littlefs ones in development builds |
| [design-usb.md](design-usb.md) | USB: xHCI, hubs, HID and mass storage |
| [design-network-stack.md](design-network-stack.md) | erXos's TCP/IP stack, translated from FreeBSD into Erlang, and its fast path (runs, receive merging, batching, benchmarks); [Networking](#networking) holds the choices that bound it |
| [design-wifi.md](design-wifi.md) | WiFi on the Raspberry Pi 4's CYW43455 |
| [design-crypto.md](design-crypto.md) | cryptography: OpenSSL in the runtime images, OTP's crypto applications, HTTPS clients |
| [design-ssh.md](design-ssh.md) | SSH: the SSH domain, logins, keys and channels |
| [design-login.md](design-login.md) | logging in through a front end: the system domain's one `login` facet for SSH, the web and `bleuart`'s root line |
| [design-bluetooth.md](design-bluetooth.md) | Bluetooth Low Energy, peripheral first, and `bleuart`, root's shell over Nordic's UART service |
| [design-live.md](design-live.md) | the live machine: console, ttys, attributed text, the inspector and `/proc`, tracing, the code store and loading code by the host link, SSH or a file, the host link |
| [design-shell.md](design-shell.md) | the command shell: rc's language, the command namespace, text pipelines, job control |
| [design-vi.md](design-vi.md) | evi, the screen editor run as `vi` |
| [design-display.md](design-display.md) | the display: composition, input routing, window buffers, the draw protocol, the terminal, widget trees, kiosks, graphics hardware |
| [design-desktop-programs.md](design-desktop-programs.md) | the desktop's own programs and the shared visual theme |
| [design-find-act.md](design-find-act.md) | find and act: the desktop session's palette and routes from values to rc lines |
| [design-apps.md](design-apps.md) | apps as principals, the start table and `service` |
| [design-packaging.md](design-packaging.md) | packages: one file per app, admission, install and update at run time, the SDK |
| [design-app-trees.md](design-app-trees.md) | an app's own tree at `/svc/NAME` |
| [design-web.md](design-web.md) | the web client and its two front ends |
| [design-log.md](design-log.md) | the system log |
| [design-time.md](design-time.md) | network time and the clock service |
| [design-generation.md](design-generation.md) | generated interface bindings, inspection, catalogs, test scaffolding, and the hardware and terminal sources |
| [design-abi.md](design-abi.md) | the declaration grammar, layouts, bounded readers and numeric assignments |
| [design-build.md](design-build.md) | the build and host tooling: deadlines, source records, evidence boundaries |
| [design-host-oracle.md](design-host-oracle.md) | the stock OTP oracle in an isolated Linux container |
| [design-verification.md](design-verification.md) | pure protocol cores, TLA+ models and model-to-code evidence |
| [design-bench.md](design-bench.md) | the benchmarks: the record, the one clock, the comparison rule, the three hard limits, the other systems on the same board |
| [plan.md](plan.md) | milestones, exit criteria and decision gates |
| [style.md](style.md) | code style |
| [todo-simplification.md](todo-simplification.md) | unadopted alternatives and their evidence |
| [TODO.md](../TODO.md) | open work outside the roadmap |
| research records | point-in-time evidence, listed in [References](#references) |

## Context

Erlang systems already behave like operating systems: millions of isolated
processes, preemptive scheduling, failure handled by links and
supervisors, code replaced while running. On a conventional OS, that
system runs as one process inside another system's abstractions, and every
boundary the OS draws (processes, threads, file descriptors, users) is
invisible to it. erXos makes the Erlang process the system's process and
draws hardware protection around groups of processes where trust requires
it, not around a runtime that would rather see none.

The user's statement of the problem: "make real kernel threads and
internal light erlang threads visible to the main scheduler and have it
schedule across all of them". Two answers have been tried for thirty years
([research](research-hierarchical-scheduling.md)). One gives every
lightweight thread to the kernel, which makes each spawn and switch a
kernel operation. The other lets user-level schedulers multiplex
lightweight threads on kernel threads, and its general-purpose versions
(scheduler activations in NetBSD, KSE in FreeBSD, M:N threads in Solaris,
user-mode scheduling in Windows) were abandoned
([research](research-hierarchical-scheduling.md#negative-evidence)). Their
failures share a cause: a kernel that re-entered a user scheduler at
arbitrary points, for arbitrary C code that could block anywhere. erXos's
situation differs in the two ways that matter. Its runtimes are few and
its own, and its lightweight processes are Erlang's, which never block a
thread. So erXos keeps the two levels and removes the causes: the kernel
never re-enters a runtime, executors never block, and everything the
runtime tells the kernel is a hint the kernel bounds.

The idea has a lineage ([research](research-prior-art.md)). Singularity
showed that a system can be organised around a language runtime and
measured what hardware crossings cost; SPIN and JX loaded extensions under
language safety; Inferno put a VM at the centre; Genera made the whole
machine an inspectable, modifiable environment. Psyche, Barrelfish and
Akaros explored how a runtime and a kernel share CPUs; Fiasco and seL4
showed how far a small capability kernel goes, and Genode runs components
under CPU quotas and memory per session. Safe Erlang made pids and nodes
into capabilities, and Zircon removed ambient authority. erXos takes from
each: a small capability kernel with time as a resource, runtimes that
keep their own scheduling, services that spend only their own grants,
capabilities beside a global name space, and a live machine.

The first target is QEMU's `virt` machine for AArch64, under TCG and under
HVF on Apple Silicon, with 4 KiB pages ([research](research-baselines.md),
[research](research-kernel-bases.md#qemu-virt-under-tcg-and-hvf)). What
the kernel needs of an architecture is its port contract
([design-kernel.md](design-kernel.md#port-contract)), and two bindings say
how AArch64 and each platform provide it
([design-arch-aarch64.md](design-arch-aarch64.md),
[design-platforms.md](design-platforms.md)). Fiasco's kernel-mode build
boots under both accelerators
([research](research-hierarchical-scheduling.md#fiasco-under-hvf)).

## Requirements

Functional requirements:

1. **Run Erlang applications.** OTP 29.1.2 applications run unmodified
   inside a domain, with Erlang's semantics for processes, messages,
   links, monitors and code loading, checked against stock OTP 29.1.2 on
   the development host. Domain crossings use explicit authority and the
   bounded transport contract of
   [design-domains.md](design-domains.md#compatibility-and-migration).
   Each domain is an Erlang node of its own, so placing an application
   across domains behaves as placing it across connected nodes, with the
   differences that document lists; it is not promised to be invisible.
   The common pid and
   inspection view unifies naming without erasing these boundaries.
2. **Protection.** Untrusted Erlang code, drivers and native programs run
   in domains, or in sub-spaces of a domain, that cannot read, write,
   crash or exhaust anything outside themselves beyond what they were
   granted.
3. **One system.** One pid space, one message system and one view of
   identity, supervision and inspection span every domain and every
   runtime; one CPU authority schedules every thread.
4. **Generic runtimes.** The kernel knows no runtime; ERTS runs on a
   contract of groups, grants, park and wake that any runtime could, the
   native threads of sessions' programs share the machine by the same
   grants, and the contract does not preclude other runtimes.
5. **A live machine.** A shell on the console, behind a login in release
   builds, from which every process, domain and kernel object can be
   inspected, traced and changed by whoever holds the authority; code
   loaded from the development host while the machine runs.
6. **Drivers.** Drivers as supervised Erlang processes in domains that
   hold their devices, with MMIO, interrupts and DMA carried by kernel
   capabilities through one device NIF; virtio first.
7. **Users.** Principals with budgets, CPU shares and quotas; each user
   gets a default domain and may create more.
8. **Storage, updates and networking.** Storage that survives power cuts,
   system updates that leave a bootable system whatever happens, and
   networking to other machines, each a service in domains of its own.
9. **UNIX programs where they pay.** Per-domain namespaces of file
   servers; a command shell with rc's language and toybox's applets; UNIX
   programs recompiled against a POSIX-lite personality and run as ports
   of their sessions.

Non-functional requirements:

* **Performance.** Process switch, spawn and messaging inside a domain
  within 1.2 times stock ERTS on the same host; cross-domain messaging an
  order of magnitude cheaper than distribution between nodes; an idle
  domain costs no CPU ([Performance](#performance)).
* **Security on equal footing with correctness.** Every input that crosses
  a trust boundary is validated with bounded work by the party that bears
  its consequences, on that party's own grant.
* **Reproducibility and determinism.** Identical inputs give
  byte-identical boot images and EROFS images; a deterministic boot mode
  gives byte-identical transcripts.
* **Portability.** QEMU `virt` first, then the Raspberry Pi 4 Model B and
  the Raspberry Pi 5, each behind the kernel's platform layer; macOS on
  Apple Silicon is the primary development host, then Linux.

Non-goals:

* POSIX as the base. POSIX is an optional personality for native
  domains, never the base: nothing above the kernel interface depends on
  it, and no Erlang code sees it but a session's command server and
  handlers, which speak its process protocol. Linux binaries and a Linux
  virtual machine are not provided
  ([Alternatives considered](#alternatives-considered)).
* Confidentiality between processes of one domain, or against speculative
  side channels within one address space.
* Runtimes other than ERTS; the contract leaves room for them.
* Running unmodified ERTS: erXos owns its runtime.

## The model

Seven concepts, each with one owner:

| Concept | What it is | Owner |
| --- | --- | --- |
| **Process** | the unit of execution and failure: a pid, a mailbox, links and monitors. Its pid names its owner domain | the domain's runtime ([design-domains.md](design-domains.md#domain-ids-pids-and-references)) |
| **Domain** | the unit of isolation: an Erlang node with a name of its own, a space, a runtime with its own atoms, code, ETS tables and names, a budget, a group, a connection to the system domain, and a domain pid that stands for it | the system domain ([design-system.md](design-system.md#creating-a-domain)) |
| **Runtime** | the code in a domain that schedules lightweight processes on executors: ERTS | its domain ([design-runtime.md](design-runtime.md)) |
| **Group** | the unit of CPU time: a kernel object holding threads, with a **grant** (quota per period, cpuset, capacity, urgency band); groups form a tree, and no group exceeds its parent | the kernel ([design-scheduler.md](design-scheduler.md#data-model)) |
| **Budget** | the unit of memory: a kernel object carved from its parent's that pays for every object and page, with a **guarantee**, memory set aside for it that no other budget can take, and a **cap**, up to which it spends what its ancestors have promised to no one; its carver resizes both; deleting it deletes every object charged to it and every budget carved from it, at once, as EROS's space banks do | the kernel ([design-kernel.md](design-kernel.md#budgets)) |
| **Capability** | the unit of authority: a kernel **capability** (an object reference with rights) or a domain's **export** (one of its own pids or aliases, exported to one peer domain with rights). Rights only shrink | the kernel for capabilities, each domain's runtime for its exports ([design-domains.md](design-domains.md#exports)) |
| **Principal** | the unit of identity: a user with a budget, a group, quotas and sessions | Erlang policy in the system domain ([design-domains.md](design-domains.md#principals-sessions-and-quotas)) |

Supporting terms, each defined in the document that owns it:

| Term | Meaning | Owner |
| --- | --- | --- |
| **executor**, **worker** | a thread of a group that only parks and never blocks; a thread that may block | [design-scheduler.md](design-scheduler.md) |
| **ready list**, **epoch** | a group's list of the IRQ objects bound to it that have fired and not been taken, each listed once however often it fires; a group's counter that every wake, trigger and capacity change advances and that a park compares, so a wakeup between a runtime's last look and its park cancels the park | [design-scheduler.md](design-scheduler.md#park-and-wake) |
| **capacity**, **run** | the CPUs of sustained concurrency the resource policy advises a group to expect, in thousandths; the CPUs of the group's cpuset on which that advice places it, as many as the capacity rounded up and at least one, where its runtime keeps its active executors | [design-scheduler.md](design-scheduler.md#status-words-and-capacity) |
| **connection**, **lane** | the one transport between two domains that have been introduced: two lanes, one per direction, made by the system domain, which alone holds the delete right to their objects; one direction of a connection: a **ring** the producer alone writes, a **reader page** the consumer alone writes, and a **doorbell**, an IRQ object bound to the consumer's group, charged to the reader's outer budget, and both lanes of a domain's connection to the system domain to that domain's | [design-domains.md](design-domains.md#connections) |
| **node name** | a domain's name as an Erlang node: its identifier at the machine's host name, such as `web@erxos` or `system@erxos`, with the domain id as the node's creation | [design-domains.md](design-domains.md#domain-ids-pids-and-references) |
| **own budget**, **outer budget** | the two budgets the domain library carves side by side for each domain from the same parent: the own budget pays for what the domain alone maps and is destroyed at once when the domain ends; the outer budget pays for whatever another domain maps, each connection through a child budget of its own, and for the domain's crash area; the domain holds no capability to it | [design-system.md](design-system.md#ending-a-domain) |
| **frame**, **funnel** | one signal crossing a domain boundary, on a lane; the receiving runtime's one reader of its lanes, a C17 library in `liberx`, which copies a frame out of the ring once, validates its structure and its authority against the domain's own export table, and then decodes it, in safe mode in the system domain | [design-domains.md](design-domains.md#the-funnel) |
| **export**, **export table** | one of a domain's own pids or aliases, or its own name, made reachable to one peer domain with rights, by handing it out, by a spawn or by `erx:export/3`; the holders of each name, which the domain's runtime alone writes | [design-domains.md](design-domains.md#exports) |
| **facet**, **handle** | a process of the system domain that stands for one grant to one grantee domain, and acts only for its grantee, the domain whose lane its requests arrive on; a value a facet mints from its own scope, which privileged service helpers take in place of bare request names | [design-domains.md](design-domains.md#facets), [design-domains.md](design-domains.md#authority) |
| **log service**, **log facet** | `erx_syslog`, the system domain's service that takes the kernel's log ring, renders every log record as one attributed, escaped line, and hands it to the console and the store; the write-only facet, one operation `write`, through which a domain's logger events reach it | [design-log.md](design-log.md) |
| **system domain**, **root task** | the Erlang domain whose services decide policy and whose domain library builds and ends every other domain; the one task the kernel starts, which the system domain is | [design-system.md](design-system.md#the-root-task) |
| **domain service**, **domain library** | the Erlang service that admits, records and ends domains; the C17 library in `liberx`'s system layer, called through NIFs, that plans a domain whole and creates, inspects and ends it | [design-system.md](design-system.md#the-domain-library) |
| **sub-space** | a space a domain creates within its own budget for code it chooses to run, holding only what its creator gives it and ending with its creator | [design-kernel.md](design-kernel.md#creating-spaces) |
| **pass set** | the rights a capability of a type keeps when it passes to another space; a type whose pass set is empty never passes | [design-kernel.md](design-kernel.md#rights) |
| **namespace** | a domain's table from paths to file servers | [design-files.md](design-files.md) |
| **program**, **port** | a native program of a session, running in a sub-space of the session's domain; what the program is to the session's Erlang, owned by a process, linked, closed with its owner and reporting `{exit_status, N}` | [design-programs.md](design-programs.md#a-program-is-a-port) |
| **channel** | the program's one way out, a lane pair with doorbells between its sub-space and the session, over which every request it makes travels | [design-programs.md](design-programs.md#the-channel) |
| **handler** | the session's Erlang process that serves a program's requests with the session's authority, after checking the program's own table | [design-programs.md](design-programs.md#the-handler) |
| **anchor**, **image** | a program's threadless space, kept for the program's whole life, below which its images and the anchors of the programs it starts hang; the space whose threads run a program's code, which each `exec` replaces | [design-programs.md](design-programs.md#a-program-is-a-port) |
| **pipe** | a one-way byte stream in user space, which carries programs' standard streams: a ring in memory that the session's pipe server makes and maps into the sub-spaces of both ends, with IRQ objects as doorbells that the session makes, as it makes the ends | [design-pipes.md](design-pipes.md) |
| **driver**, **device NIF**, **device shim** | an Erlang process under a supervisor, in a domain that holds its device's capabilities; the one module, `erx_device`, through which a driver reaches registers, descriptors, DMA buffers and interrupts; the NIF's C, the thin C under every driver, which parses nothing a device wrote | [design-system.md](design-system.md#drivers), [design-runtime.md](design-runtime.md#the-device-nif) |
| **native shim** | any native driver code other than the device NIF, a stopgap or third-party driver included, which runs as a sub-space port of its driver's domain and exists only as a row of the driver table | [design-system.md](design-system.md#drivers) |
| **devices domain**, **PCIe domain**, **driver table** | the domain that holds the slow devices other than the UARTs of the console and the host link, and no configuration space, outside the trusted base without exception; the one domain, `pcie` in the system manifest and the node `pcie@erxos`, that holds PCIe configuration space and nothing else and runs the PCIe enumerator, in the trusted base whole; the table in [design-system.md](design-system.md#the-driver-table) of every native shim, each a row with what justifies it | [design-system.md](design-system.md#devices) |
| **watchdog**, **crash record**, **machine reset** | the kernel's one watchdog, armed at the root task's start and petted by the system domain's watchdog process once the services it lists have answered; what the kernel writes before the machine ends, brief in release builds and full in development builds, shown at the next boot only to the system shell; how a fault of the system domain, a missed watchdog or `erx.panic` ends the machine, through the firmware interface | [design-kernel.md](design-kernel.md#the-watchdog), [design-system.md](design-system.md#the-root-task) |
| **boot image** | the archive that holds everything the machine starts with | [design-kernel.md](design-kernel.md#the-boot-image) |
| **bootable file** | the one file a loader boots: the first stage, erXos's kernel or Fiasco's `bootstrap`, with the boot image inside it | [design-kernel.md](design-kernel.md#the-bootable-file) |
| **system manifest** | the one file of the system configuration, packed by the build into the boot image: every configured domain with its principal, image, budget, grant, devices, facets and introductions, proved at build time by the manifest check | [design-system.md](design-system.md#the-manifest) |

## Overview

```text
 user mode
  +----------------------+ +----------------------------+ +--------------------+
  | domain "web"         | | domain "alice", a session  | | storage domain     |
  |  ERTS (BeamAsm)      | |  ERTS: shell, apps,        | |  ERTS: F2FS, FAT,  |
  |  processes <7.N.S>   | |  handlers, pipe server     | |  the block driver  |
  |  executors | workers | |  +----------+ +----------+ | |  over erx_device   |
  |                      | |  | ls       | | wc       | | |  (the device NIF)  |
  |                      | |  | sub-space| | sub-space| | |                    |
  |                      | |  +-channel--+ +-channel--+ | |                    |
  +----------+-----------+ +-------------+--------------+ +---------+----------+
             | connection                | connection               | connection
  +----------v---------------------------v--------------------------v--------+
  | system domain (ERTS, interpreted; the root task): the domain service     |
  | over the domain library (liberx), the device service, the system         |
  | manifest, principals, facets, resource policy, console, inspector,       |
  | tracer, host link                                                        |
  +--------------------------------------------------------------------------+
 -----------------------------------------------------------------------------
 kernel mode
  +--------------------------------------------------------------------------+
  | kernel (C17): capabilities, budgets, spaces, memory objects, threads,    |
  | groups and grants, IPC gates, IRQ objects, umtx, vCPU upcalls,           |
  | interrupts, IOMMU, time, entropy, early console, trace, the watchdog;    |
  | or, until it replaces it, a near-stock Fiasco behind the same interface  |
  +--------------------------------------------------------------------------+
```

Two domains that the system domain has introduced to each other share a
connection of their own, drawn here only toward the system domain.

What runs where:

| Component, mode | Runs | Trusted by | Fails how |
| --- | --- | --- | --- |
| kernel, kernel mode | objects, scheduling, memory, interrupts, the watchdog | everything | a bug is a kernel bug; nothing a domain does panics it |
| system domain, user mode | the root task: `liberx`'s root-task entry, the domain library, and on the interpreter, with no JIT, the system services and the system shell, which only a login at a secure console line opens | every domain, for policy and for having been built | a fault, or a halt outside ordered shutdown, resets the machine after a crash record; every domain's space is its child and ends with it |
| Erlang domain, user mode | a runtime and a domain's Erlang code, possibly untrusted | itself; its own runtime decides who may signal its processes | the domain dies; links and monitors to it fire with `{domain_down, D, Info}` |
| driver domain, user mode | an ERTS whose supervised processes drive the domain's devices through the device NIF; where the driver table lists one, a native shim as a sub-space port | itself, and the kernel as far as its devices' DMA is confined | a driver process crashes and its supervisor restarts it, resetting the device; the domain dies as any Erlang domain does |
| session program, user mode | a sub-space of its session's domain running one native program: one of toybox's applets, a recompiled UNIX program, `rc` | itself; its session, for everything it reaches | the sub-space ends, with every sub-space it started; the port's owner gets `{exit_status, N}` |

A day in the life. The kernel boots from the image the boot loader handed
it, validates the device tree and the boot image, starts the other CPUs
and starts one task, the system domain. `liberx`'s root-task entry takes
the root capabilities, builds the domain's memory, threads and group, and
starts ERTS, which boots OTP's `kernel` and `stdlib` and the system
release: the domain service, which creates every domain the system manifest
lists, the device service, which gives each device to the domain the
manifest names, the drivers, storage, the network, the vault, the
console, with a login at each of its lines, where a development build
logs `root` in at the UART, and at the host link's `console` line when the host opens it, and opens the system shell there. A user
logs in; the domain service plans the user's domain through the domain
library: a budget, an outer budget and a group carved from the
user's, a space whose parent is the system domain's, a connection to the
system domain, and an ERTS that boots its own small release as the node
`alice@erxos`. Inside the domain,
processes message each other without the kernel; an idle domain's
executors park. A process sends to a system service it was given a facet
for: its runtime encodes the frame into its lane's ring and rings the
doorbell if the system domain is parked; the system domain's funnel copies
the frame out, checks it against the lane it came on and the export table,
decodes it in safe mode, and the facet's reply travels back on the other
lane. The user's shell spawns a process into a sandbox domain, linked; the
sandbox crashes; its fault reaches the system domain's fault gate, the
domain service ends the domain by destroying its budget, which deletes
everything the domain paid for at once, takes its connections down, and
the process link delivers `{domain_down, D, crash}`. The user types
`find /tmp -type f | wc -l` into the command shell: the session starts
`find` as a port, in a sub-space with a channel to its handler and the
pipe's ring mapped by the session's pipe server, runs `wc` as an Erlang
command that reads the pipe's other end, and collects the program's exit
status. When two of the session's programs map one file shared, the
session's mapper process holds one memory object for it, filled with
ordinary reads from the file's server, maps it into both, and writes back
with ordinary writes only the pages the kernel reports stored.

The machine's configuration and its updates each have one source. The
system manifest lists every configured domain, and a Ruby check at build
time fails the build when it breaks a property the security argument rests
on, such as a release build's domain that parses hostile input holding
an unconfined device. An update's whole state is the boot-selection
record, which names the committed slot, with the firmware's one-shot
trial request:
`normal(C)` boots the committed slot C and lets the spare be written, and
`trial(S)` boots the spare S once, after which the machine returns to C
unless S is committed. A spare is bootable only if it verifies against its
update manifest at boot, so a spare left half-written needs no record of
its own ([design-storage.md](design-storage.md#system-updates)).

## Invariants

System-wide properties, each held by construction in the subsystem that
owns it. The owner's invariant table gives the full mechanism and the
checks.

| Invariant | Held by | Owner |
| --- | --- | --- |
| The kernel never runs runtime code at a preemption, and a preempted executor resumes where it stopped | the kernel enters user mode only by resuming saved state or by a vCPU upcall to a worker armed for signals; arming refuses an executor | [design-scheduler.md](design-scheduler.md#invariants) S1 |
| No wakeup is lost | every trigger, capacity change and wake advances the group's epoch, which a park compares under the same lock | design-scheduler S2 |
| An executor never blocks except to park, or on a umtx word in its own domain's private memory | executor attributes in the ABI file; generated dispatch refuses every other wait | design-scheduler S3 |
| No group exceeds its parent, whatever a runtime reports | quotas charged along the whole path; urgency clamped to the path's ceilings | design-scheduler S5 |
| A stale capability never names a new object | one lookup checks generation, type and rights; a slot retires before its generation wraps | [design-kernel.md](design-kernel.md#invariants) |
| Rights only shrink | creation, copy, pass and fork's copy each intersect rights; no peer widens an export | design-kernel K2, K17; [design-domains.md](design-domains.md#invariants) D4 |
| Every kernel allocation is charged to a budget, and an object dies with its budget | one charging funnel; deleting a budget deletes everything charged to it and carved from it at once | [design-kernel.md](design-kernel.md#invariants) K25, K26 |
| The kernel reaches a domain's memory only as UTCB fields or as (object, offset, length) through its own mapping | no pointer type in the ABI grammar; a user address converts to no pointer; umtx translates its one address through the caller's page table | [design-kernel.md](design-kernel.md#invariants) |
| A mapping never allows more than the capability that made it | each mapping's ceiling is fixed from the capability's rights | [design-kernel.md](design-kernel.md#invariants) |
| Trimming never meets sharing | only private memory, which has no capability and is mapped once, is freed by range | [design-kernel.md](design-kernel.md#invariants) |
| Copy-on-write shares only immutable pages | a parent is never written, a child is never a parent, and the child reserves its pages at creation | [design-kernel.md](design-kernel.md#invariants) K22, K23 |
| No page is executable while another mapping or a confined device can write it, except a JIT object's pages in the one space that made them, and the kernel writes no machine code | the kernel refuses a mapping that is both; JIT objects only in spaces whose image allows them, never the system domain's | [design-kernel.md](design-kernel.md#invariants) K8 |
| No register page and no interrupt line is held by two domains | devices sharing a page or line are one unit given whole to one domain; PCIe interrupts by MSI except on the Pi 4's closed bus | [design-shared-devices.md](design-shared-devices.md#invariants) SD1, [design-pcie.md](design-pcie.md#the-closed-bus) |
| A pin has one owner, and one process writes a pin controller | the board's pin table has one row per pin, checked at build; the pin driver alone has a name for a pin register, and its record holds no row for the console's pins | [design-pinctrl.md](design-pinctrl.md#the-construction) |
| A pid never names two processes | a pid carries its owner's creation, a domain id never reused within a boot | [design-domains.md](design-domains.md#invariants) D1 |
| A domain reaches only what was exported to it, and cannot tell an unexported process from a dead one | the receiver's funnel decides from its own export table, and a refused operation gets what one on a dead process gets | D4, D9 |
| Every frame a runtime accepts passed its funnel | a runtime reads a lane's ring only through the funnel, which copies each frame once | D3 |
| The system domain's atom table grows only within bounds policy sets | no frame creates an atom there; node names only, within the principal's `names` quota ([design-system.md](design-system.md#identifiers)) | D5 |
| A domain speaks only for its own processes | the lane names the sender; no frame field is trusted for identity | D6 |
| No process acts on a message from another domain that the owner of its protocol did not admit | every such message arrives as `{erx_origin, D, Msg}`, and only each protocol's owner unwraps its own shapes | D18 |
| What a domain can make another hold is bounded by the receiver's own limits, what it can make the system domain hold is a sum reserved at its admission, and no domain can make another wait on it | rings charged to the reader's outer budget, both lanes of a domain's system connection to that domain's, and sized by the reader's policy; per-process queue quotas leave frames in the lane; the domain service reserves each domain's worst case in the system domain's budget | [design-domains.md](design-domains.md#flow-control), [design-system.md](design-system.md#resource-policy) |
| A client cannot spend a service's CPU or memory beyond the service's admission | the service's own capped grant; per-client facet and lane bounds; lazy decoding; bounded control steps | [design-scheduler.md](design-scheduler.md#service-work), [design-domains.md](design-domains.md#facets) |
| No capability is ever in flight, and only a space's creator installs capabilities into its table unasked | capabilities pass only at a rendezvous into reserved slots; `CAPS` comes only with a space's creation and leaves with `INSPECT` alone | [design-kernel.md](design-kernel.md#invariants) K17; [design-system.md](design-system.md#invariants) A1, A7 |
| Only a space's creator conveys code, device and structural authority, and `CODE` never leaves the system domain's table | pass sets hold no right to execute, make code or reach a device | [design-kernel.md](design-kernel.md#invariants) K8, K24 |
| A forked child executes only the code its parent had mapped | `erx_space_copy` shares only immutable executable objects | [design-kernel.md](design-kernel.md#invariants) K8, K24 |
| Deleting an object invalidates every capability to it at once, and memory mapped from it faults from then on | flat capabilities; a deletion closes the existence lock first, then unmaps, and frees after an RCU grace period | [design-kernel.md](design-kernel.md#invariants) K25, K26 |
| A server never maps memory a client can delete or end, and no party to a connection can make the other fault | memory crosses a domain boundary only through objects the system domain made and charged to a budget that outlives every mapper; otherwise a server copies with `erx_mem_copy`, which fails instead of faulting | [design-kernel.md](design-kernel.md#closing-and-deleting); [design-system.md](design-system.md#authority); [design-domains.md](design-domains.md#connections) |
| Nothing outlives its creator | every space has a parent fixed at creation and stops with it; a program's children hang from its anchor, so they survive its `exec` | [design-kernel.md](design-kernel.md#creating-spaces); [design-programs.md](design-programs.md#a-programs-end) |
| No grant writes and runs a file together, and only an `rx` grant runs one | rights are one of `ro`, `rw`, `rx` | [design-files.md](design-files.md#invariants) F6 |
| A file's bytes mapped shared live in one place per session | one mapper and one memory object per mapped file per session | [design-files.md](design-files.md#invariants) F7 |
| An update always leaves a bootable committed system | slots written only under `normal(C)`; only a complete spare is tried | [design-storage.md](design-storage.md#system-updates) U1 to U5 |
| A path never reaches a file server the domain does not hold, nor anything above its grant's root | a namespace entry stores only a grant's pid; the server fixes the root and follows no link in a walk | [design-files.md](design-files.md#invariants) F1, F2 |
| A pipe's reader sees the end of the stream once every writer has gone and every byte written has been read | the session installs every end and keeps every ring until drained | [design-pipes.md](design-pipes.md#invariants) PI1, PI2 |
| A command acts only through the capabilities it was handed, and one with less than its session's runs in a space of its own | facets in the command's context; command domains and sub-spaces built from exactly what the starter named | [design-shell.md](design-shell.md#invariants) SH1, [design-programs.md](design-programs.md#invariants) P2 |
| A program's bytes reach a terminal as its tty's flags leave them | one owner per tty and one pure output function | [design-live.md](design-live.md#invariants) V1 |
| Text labelled with its source is displayed only through the line escape | one generated escape table | [design-live.md](design-live.md#invariants) V9 |
| Only the system shell types expressions into the system domain, and only a login at a secure console line opens it | the system-shell facet, held by the console for that login alone | [design-live.md](design-live.md#invariants) V6 |
| The kernel, `liberx`, the runtimes and Erlang agree on the ABI, and code agrees with the hardware's registers | everything generated into `build/gen/` from one source each | [One source](#one-source-for-the-abi-and-the-hardware) |
| No kernel stack overflows | a per-build stack proof, `musttail`-only recursion, guard pages | [Bounded stacks](#bounded-stacks) |

## Decisions

Decisions that constrain more than one subsystem, each with its reason.
The detail, the numbers and the exceptions live in the document the last
column names.

| Decision | Rationale | Specified in |
| --- | --- | --- |
| **Hierarchical scheduling with grants is the normal execution model.** The kernel schedules threads within groups' grants; runtimes schedule lightweight processes on their executors. | ERTS's scheduler switches processes without entering the kernel and is proven; the kernel needs one authority over CPU time for every thread, native or runtime. | [design-scheduler.md](design-scheduler.md) |
| **The six rules of the two-level contract.** Executors are ordinary preemptible threads; preemption never runs runtime code; wakeups and capacity changes are queued events taken at safe points; executors never block except to park, a umtx wait in the domain's own private memory counting as inside the domain; budgets are enforced whatever the hints say; there is no donation. | Each rule removes a failure that ended an earlier two-level system: re-entrancy, lost events, executors lost to blocking, trust in user-reported state, and a scheduling dependency between domains ([research](research-hierarchical-scheduling.md#negative-evidence)). | [design-scheduler.md](design-scheduler.md#context) |
| **erXos's own C17 kernel on Fiasco's design; a near-stock Fiasco as the kernel of Phase 1 and of the first release.** The interface is erXos's; `liberx`'s Fiasco backend implements, above Fiasco, the part that Phase 1's system and 0.2 use. After 0.2, Fiasco is improved to a stated point and gate GF of [plan.md](plan.md#track-f-fiasco-improved-to-the-decision) decides whether erXos's kernel replaces it, which is then gated on the conformance suite. | A working system first, on proven code, without Fiasco's model leaking above the interface. The price is work done twice where a subsystem needs erXos's kernel ([plan.md](plan.md#02-the-first-release-on-fiasco)); [what erXos's kernel adds](design-kernel.md#what-erxoss-kernel-adds-in-brief) says what each difference buys. | [design-kernel.md](design-kernel.md#the-current-implementation-the-modified-fiasco), [plan.md](plan.md) |
| **The kernel keeps Fiasco's model wherever erXos needs nothing else.** Every departure is in the kernel's L4 lineage ledger with its reason. | The user's standing principle, to minimise needless changes from the L4 model; Fiasco's know-how comes with its model. | [design-kernel.md](design-kernel.md#l4-lineage) |
| **The first release ships on Fiasco, with Fiasco's own mechanisms.** The root creates and places every object and each holder invokes its own Fiasco capability; budgets are walls and CPU is priority bands; what Fiasco lacks against erXos's kernel is a published list of downsides, not rebuilt in user mode. | Fiasco is a proven kernel with capabilities, quotas, an IOMMU binding and MSIs, so a release with every user feature need not wait for erXos's kernel; a downside closes on Fiasco where the fix fits Fiasco's approach, and the rest when erXos's kernel replaces Fiasco, if gate GF chooses it. | [design-fiasco.md](design-fiasco.md), [plan.md](plan.md) |
| **The Fiasco fork is frozen and owned.** Upstream is tracked for security fixes alone while a release runs on it; new C++ only where it integrates with Fiasco, with the policy behind it in C17. | The C17 cores move to erXos's kernel unchanged. | [design-fiasco.md](design-fiasco.md#upstream-security-fixes) |
| **Every runtime in user mode**, the system domain's ERTS too. | A runtime's fault ends a domain, not the machine; the kernel writes no machine code and carries no runtime. | [design-runtime.md](design-runtime.md) |
| **The system domain runs the interpreter.** ERTS's two builds make three runtime images: the system image (interpreter, no JIT, no C++, no OpenSSL), the interpreter image and the BeamAsm image, both with OpenSSL; ordinary domains run BeamAsm by default. The development and website manifests run storage and network on the interpreter, and the net_device suite's exchange cell runs the network domain on BeamAsm for its throughput figure. | No JIT object, no C++ and no OpenSSL code exists in the trusted base, whose bounded control loses little to the interpreter, while the domains that do the heavy work keep the JIT. BeamAsm compiles every module it loads, so a development boot of several runtimes on one CPU reaches the prompt sooner on the interpreter ([todo-performance.md](todo-performance.md)). | [design-runtime.md](design-runtime.md#beamasm), [design-crypto.md](design-crypto.md#three-runtime-images-and-openssl-in-two-of-them) |
| **The kernel never dereferences a user address.** An argument is a register, a UTCB field read once through generated accessors, or a memory window (object, offset, length) reached through the kernel's own mapping; umtx alone translates an address, through the caller's page table. | A request cannot change between check and use, and a domain cannot aim the kernel at memory, by construction: the kernel has no user-copy functions, no fixup table and no window in which it touches user memory. | [design-kernel.md](design-kernel.md#invariants), [design-runtime.md](design-runtime.md#liberx) |
| **`liberx` is the only issuer of kernel calls**, with backends for erXos's kernel, Fiasco and a hosted implementation. | Seams, not rewrites: nothing above `liberx` changes when the kernel does. | [design-runtime.md](design-runtime.md#liberx) |
| **Every domain is a node, and a pid carries its owner domain.** Each domain is an Erlang node named by its identifier at the machine's host name, with its never-reused domain id as the node's creation; a connection between domains is a stock distribution connection, and a pid prints as `<D.N.S>` everywhere. | Uniqueness, locality and stale-pid safety by construction, with no registry; stock node identity does the work. The differences from stock (registered-name sends, `global`, `pg`, the channel-number macros) are documented with tests. | [design-domains.md](design-domains.md#domain-ids-pids-and-references), [design-runtime.md](design-runtime.md#erlang-visible-behaviour) |
| **Every cross-domain signal travels on a connection, and the receiver's funnel checks it.** A connection is two lanes the system domain makes when it introduces two domains; who may signal a domain's processes is an export table its own runtime owns; a malformed frame ends the connection from the receiver's side. | Identity holds by construction, since the lane names the sender; a frame is validated by the party that bears its consequences, on its own grant; flow control is the ring; and no third party carries frames. The cost is two lanes per introduced pair ([Alternatives considered](#alternatives-considered)). | [design-domains.md](design-domains.md#connections), [design-domains.md](design-domains.md#the-funnel) |
| **Payload identity and operation authority are separate.** Pids of other domains travel unchanged in a payload; only the owner handing out a name, a spawn or an explicit export writes an export; privileged helpers take facet-minted handles, never bare names. | Preserving data identity avoids map-key corruption, and one admission boundary prevents confused deputies without rewriting terms. | [design-domains.md](design-domains.md#exports), [design-domains.md](design-domains.md#authority) |
| **Shared services run on their own grant and do bounded control.** No thread runs on another group's time; a service admits per client through that client's facet and lane, and work that grows with a client's input runs in the client's domain or fairly within the service's grant. | A capped grant per service needs no payer, loan or account; the cost is that a saturated service slows all its clients together, as Genode's components do. | [design-scheduler.md](design-scheduler.md#service-work), [design-system.md](design-system.md#resource-policy), [design-domains.md](design-domains.md#facets) |
| **A dirty call costs its elapsed time in reductions, on either dirty pool.** | A facet admits its client by the reductions the service spends for it, and stock OTP charges a dirty I/O call one reduction whatever it takes, which would make blocking work free to its client. A documented difference from stock with a test. | [design-runtime.md](design-runtime.md#nifs-and-blocking), [design-scheduler.md](design-scheduler.md#service-work) |
| **Finishing a stopped call runs outside every quota, within a fixed finishing share of each CPU, and is counted as finishing time on the stopped thread's own groups; reclaiming is charged to the caller.** Fiasco has the level without the share, a residual of development builds. | No grant can hold an exit record back, and there is no reservation or sponsor to size: the share bounds what finishing takes from a CPU. The cost: a stopper cannot cap the finishing it causes with its own grant. | [design-kernel.md](design-kernel.md#execution-model-and-locking), [design-scheduler.md](design-scheduler.md#kernel-calls) |
| **Budgets are space banks.** Deleting a budget deletes at once every object charged to it and every budget carved from it; ending a domain is destroying its budget; what must outlive a party is charged to a budget that outlives it. | Ending a domain is one destruction with nothing left to drain and no rule for who keeps dead objects alive. | [design-kernel.md](design-kernel.md#budgets), [design-kernel.md](design-kernel.md#closing-and-deleting), [design-system.md](design-system.md#ending-a-domain) |
| **A budget has a guarantee and a cap, and a program draws on its session's pool.** A domain's budgets are walls (cap equal to guarantee); a program's budget is elastic within its session's pool; a page is charged when promised, never at a fault. | Ordinary POSIX programs behave as on QNX, refused only when the pool is full, while a domain's memory depends on nothing outside it but the kernel. | [design-kernel.md](design-kernel.md#budgets), [design-system.md](design-system.md#resource-policy), [design-programs.md](design-programs.md#the-posix-lite-personality) |
| **The system domain is the root task: Erlang policy over a C17 domain library.** The domain library plans a domain whole before applying it; every domain's space is a child of the system domain's; a fault of the system domain or a missed watchdog resets the machine after a crash record. | A separate root task would buy only that configured services ride through a system-runtime fault, at the cost of a second trusted program, reconciliation and re-grant rules; erXos takes the reset, as `heart` does, and keeps the library behind one C interface ([Alternatives considered](#alternatives-considered)). | [design-system.md](design-system.md#the-root-task), [design-system.md](design-system.md#the-domain-library), [design-kernel.md](design-kernel.md#the-watchdog) |
| **Capabilities pass at a rendezvous and are flat, as in Fiasco.** No queue holds one; between domains none passes, since no domain holds another's gate, so memory crosses a domain boundary only through objects the system domain made. | Nothing in flight means no collector; flat capabilities keep Fiasco's object space and lifetime ([design-kernel.md](design-kernel.md#l4-lineage)). | [design-kernel.md](design-kernel.md#passing-capabilities), [design-kernel.md](design-kernel.md#closing-and-deleting) |
| **Deleted memory faults, and no server maps what a client can delete or end.** | An access to memory that is gone shows where it happens rather than as silent wrong data, and deletion cannot become a way to crash a server. | [design-kernel.md](design-kernel.md#closing-and-deleting) |
| **A session serves its programs' shared mappings**, one memory object per mapped file per session, filled and written back through the file protocol. | Coherence within a session holds by construction and no fault waits on another domain; coherence across sessions is given up, since 9P2000.L cannot carry it (a documented difference from POSIX). | [design-files.md](design-files.md#shared-mappings), [design-programs.md](design-programs.md#shared-libraries-and-mappings-of-files) |
| **Signals arrive through Fiasco's vCPU interface.** A signal from outside a program is a report on its channel, raised by the program's own event executor; `SIGKILL`, `SIGSTOP` and `SIGCONT` are the session's stop, pause and resume. | Fiasco's interface rather than an erXos mechanism; preemption still never runs runtime code, and a signal stays in order with the reports it relates to. | [design-kernel.md](design-kernel.md#vcpu-upcalls), [design-programs.md](design-programs.md#signals-in-liberx) |
| **Pipes live in user space, at home in each session.** | End of stream follows from who holds the ends, which the session, the one installer of ends, knows; the data path makes no kernel call while both sides are awake; and pipes are inspectable Erlang. | [design-pipes.md](design-pipes.md) |
| **ERTS is a parts bin; the design comes first.** OTP 29.1.2 and musl enter the tree as erXos's code. | Simplicity is the measure; tracking upstream would forbid the recombination. | [design-runtime.md](design-runtime.md#the-inventory) |
| **The Erlang-visible behaviour of what erXos keeps is checked against stock OTP 29.1.2 in an offline Linux container on the development host.** | The oracle is what makes heavy modification safe; container namespaces let stock suites make peers without reaching the network. | [Testing and the oracle](#testing-and-the-oracle), [design-host-oracle.md](design-host-oracle.md) |
| **The plain configuration is the baseline; cooperation earns its place.** Each cooperation feature is a group flag with an off switch, capped machine-wide by `erx.sched`. | Two-level systems failed by adding coordination that was not needed. | [design-scheduler.md](design-scheduler.md#performance) |
| **Functional core, effects at the edge.** | Sequencing bugs come from callers that string helpers together; pure decisions are tested exhaustively on the host. | [Functional core](#functional-core-effects-at-the-edge) |
| **TLA+/TLC checks protocol models; C17 and Erlang implement the decisions.** | The user selects TLA+/TLC; independent models expose protocol errors before implementation, and generating both sides from one rule would leave that rule unchecked. | [design-verification.md](design-verification.md) |
| **The ABI and the hardware each have one source.** | Nothing is copied by hand, so nothing drifts. | [One source](#one-source-for-the-abi-and-the-hardware) |
| **Shared interface facts generate every representation**: service clients, inspection types, error mappings, log bindings, reference tables and test scaffolding. | One fact has one source across languages and tools, while hand-written cores keep policy explicit. | [design-generation.md](design-generation.md) |
| **Chokepoints are build checks; kernel stacks are proven.** | A rule "only X may do Y" holds only while it is checked; a kernel stack overflow is silent corruption unless impossible or caught. | [Chokepoint checks](#chokepoint-checks), [Bounded stacks](#bounded-stacks) |
| **Development builds run trusted code only** until the security closure, 0.2's on Fiasco or M11's on erXos's kernel. | Fiasco is hardened only as its design lists; the closure on erXos's kernel needs its construction rules. | [design-fiasco.md](design-fiasco.md#the-security-closure), [plan.md](plan.md) |
| **Languages.** New code is C17, Erlang and Ruby, with assembly only where C cannot express the operation and `make`, minimal POSIX shell and linker scripts as build glue; no Rust and no new C++, except kernel objects and scheduler hooks in Fiasco that integrate with its C++; inherited code keeps its languages (BeamAsm and asmjit in C++, OTP's Perl generators and autoconf, Fiasco's C++, preprocessor and `mk`); Python only for the Bluetooth test peer and its decoder oracle, under `test/bt/` ([design-bluetooth.md](design-bluetooth.md#on-qemu-against-bumble)). | A small set of languages the project can own. | here |
| **Inherited build machinery stays behind one seam**, one entry point each. | Keep what works; keep it replaceable. | [Build and toolchain](#build-and-toolchain) |
| **Third-party code that erXos changes enters the tree as erXos's code; code used unchanged is fetched and built out of tree.** | Forked code must be changeable in place; unchanged code stays replaceable. | [Dependencies](#dependencies) |
| **Formats are erXos's from day one**, and where a standard fits erXos implements the standard itself: the file protocol is 9P2000.L. | Seams, not rewrites; a standard at the machine's edges meets other systems without an adapter. | [Formats](#formats) |
| **No backward compatibility in development.** A change replaces the old form outright; old state that does not parse is refused with a diagnostic. | No time goes to transitions while nothing is released. | [Compatibility](#compatibility) |
| **One machine configuration under both accelerators.** The harness pins QEMU `virt`'s machine, interrupt controller, MSI frame and CPU model. | A test that passes under one accelerator only is a bug until explained ([research](research-kernel-bases.md#qemu-virt-under-tcg-and-hvf)). | [design-platforms.md](design-platforms.md#qemu-virt) |
| **`os:type()` is `{unix, erxos}`.** | OTP's path handling keys on the OS family; erXos paths are POSIX. | [design-runtime.md](design-runtime.md#erlang-visible-behaviour) |
| **QEMU `virt` first, then the Raspberry Pi 4 Model B, then the Raspberry Pi 5**, all starting CPUs and ending the machine through one firmware interface. | The Pi 4 first because QEMU's `raspi4b` helps bring-up and its SD and Ethernet sit on the SoC ([research](research-boards-storage.md#fiascos-raspberry-pi-support)). | [Portability](#portability), [design-platforms.md](design-platforms.md#firmware) |
| **System code is Erlang, drivers included; C is for per-byte primitives and device shims.** A native driver exists only as a row of the driver table carrying gate G9's measurement. Where C passes over a frame's bytes anyway, it writes the values Erlang chose and decides nothing of the protocol. | "I definitely want most drivers in erlang with exceptions only when needed or perhaps with a small C shim for perf-critical parts." Every connection, file and device is an inspectable, supervised process, and a parsing bug crashes a process instead of corrupting memory. | [Drivers and DMA](#drivers-and-dma), [design-system.md](design-system.md#the-driver-table), [design-runtime.md](design-runtime.md#per-byte-primitives), [design-network-stack.md](design-network-stack.md#the-fast-path) |
| **Erlang reaches the kernel's entropy generator through one call, open to every domain**, `erx_bytes:entropy/1`, which raises rather than substitute; unpredictable values never come from `rand`. | An Erlang entry adds no authority, as `getrandom(2)` adds none on UNIX, and one failure contract leaves no caller to invent a fallback. | [design-runtime.md](design-runtime.md#per-byte-primitives), [design-kernel.md](design-kernel.md#interrupts-time-and-entropy) |
| **The system configuration is one manifest, proved at build time.** Every consumer reads the same packed manifest; `system_reserve` leaves configuration headroom, which is not a temporal guarantee. | Security configuration has one checked source; temporal liveness stays a separate verification obligation. | [design-system.md](design-system.md#the-manifest), [Chokepoint checks](#chokepoint-checks) |
| **A device goes where its capabilities are installed, and that is configuration.** Each device goes to exactly one domain the manifest names; PCIe configuration space goes only to the PCIe domain; in a release, each unconfined DMA device's unit gets a domain of its own. | Drivers being Erlang makes placement one rule of configuration and no new mechanism; a domain that parses hostile input must never hold a device whose DMA is the whole machine. | [design-system.md](design-system.md#devices), [design-header-io.md](design-header-io.md#the-pin-controller-and-the-console) |
| **Storage and networking are services in Erlang domains of their own**, each parser in a supervised process. | A crafted medium or packet fails within one process inside one domain. | [design-storage.md](design-storage.md), [Networking](#networking) |
| **Storage keeps proven formats**: EROFS under a hash tree for read-only images, erXos's own F2FS in Erlang for read-write storage (littlefs its stopgap), and on any drive whatever FAT16, FAT32 or EROFS volume it carries, littlefs ones in development builds, each read where its failure ends only its own mount ([design-drives.md](design-drives.md)). | Each format has an independent implementation to check against: fsimg for EROFS and FAT, Linux for F2FS ([design-f2fs.md](design-f2fs.md)). | [design-storage.md](design-storage.md#data-model) |
| **The system updates through two slots and a supervised trial boot, and the boot-selection record is its whole state.** A spare is bootable only if it verifies against its update manifest at boot. | A power cut at any point leaves a bootable system, and no progress needs recording beyond the two states the firmware keeps. | [design-storage.md](design-storage.md#system-updates) |
| **The network stack is erXos's own, in Erlang, translated from FreeBSD's default TCP stack, pinned at a FreeBSD 16 commit, with no stopgap before it; loss detection and congestion control are seams. It is an ordinary OTP application, usable outside erXos.** | "take freebsd stack as a reference and translate logic to erlang ... so we don't discover problems from scratch", and a stack "that can be used independently from erXos"; FreeBSD's test suite and test host are ready oracles. Whether TCP's fast path needs native code is measured on erXos's kernel. | [Networking](#networking), [design-network-stack.md](design-network-stack.md) |
| **A domain that other machines reach is a distribution node there too**, under its own node name; a release build allows only OTP's TLS carrier. | Stock distribution semantics hold per domain and no term is re-encoded in the network domain. It costs one connection per exposed domain per remote node, remote nodes see the machine's domain structure, and a domain not exposed looks unreachable; the plain carrier authenticates by MD5 over a cookie and encrypts nothing. | [design-network-stack.md](design-network-stack.md#distribution-to-other-machines) |
| **The trusted base parses no network traffic**: the system domain holds no `net` grant. | No socket's traffic enters the system domain, so neither the socket protocol nor the system domain needs a case for the other. | [design-system.md](design-system.md#the-manifest), [design-network-stack.md](design-network-stack.md#the-grant) |
| **Cryptography is OpenSSL 3.5, and a small verifier checks update signatures.** OTP's `crypto`, `ssl` and `ssh` use OpenSSL 3.5; Monocypher's Ed25519 check, `erx_bytes:ed25519_verify/3`, checks updates and installed packages. | OpenSSL 3.5 is a long-term-support series under Apache-2.0 and what OTP's `crypto` is written against; a small verifier keeps the full library out of the system domain ([research](research-boards-storage.md#cryptography-libraries)). | [design-crypto.md](design-crypto.md), [design-storage.md](design-storage.md#system-updates) |
| **erXos's own code is BSD-2-Clause, copyright Stanislav Sedov <stas@deglitch.com>; every image carries its third-party notices, and every changed third-party file says so.** | The dependencies' licenses require their notices with every copy, and Apache-2.0 and Zlib require changed files to be marked. | [Licenses and notices](#licenses-and-notices) |
| **A path is the face of a capability.** Every domain resolves paths through its own namespace, a table from mount points to grants at file servers, with no machine-wide root. | The user adopted Plan 9's per-process namespaces; holding a path is holding a pid, so the server's exports decide what it reaches. | [design-files.md](design-files.md) |
| **File servers keep their grants' roots and speak 9P2000.L**: Erlang terms with 9P2000.L's fields inside the machine, 9P2000.L's messages at the host link and on the network. | The user adopted Plan 9's file servers and standard 9P2000.L: a compromised client cannot walk out of a root the server holds, and the protocol comes with an independent oracle and existing peers. | [design-files.md](design-files.md#the-file-protocol) |
| **System values are one read-only tree with many views; there is no `sysctl`.** `erx:i/1`, `/proc`, the host tool and a `sysctl(3)` reader are views of the inspection schema's tree; configuration is the manifest. | One tree gives one permission model, one name and one status per value, and a writable value would be a second, unproven way to change the machine. | [design-live.md](design-live.md#system-values-one-tree-many-views) |
| **Every service entry point between domains starts at a declared facet, and a new need has one of three homes.** State the system observes is an inspection path at `/proc`; what an app says, bytes someone keeps or a thing someone commands is a file tree its owner serves, with `status` and `ctl`; a live conversation is a declared protocol with its own design. Introduced processes message each other under the export rules with no facet between them, and the runtime protocol through which the root task builds and inspects every domain lies outside the rule ([design-domains.md](design-domains.md#messages-between-the-domain-service-and-a-runtime)). The test for the next case: if the system observes it and `cat` can answer it, it is an inspection path; if an app says it, or `cp` or `echo > ctl` can do it, it is a file in its owner's tree; otherwise it is a protocol, which is a design decision. | One way in for each kind of thing keeps who-sees-what to two gates, the facet's scope and the grant's root, with no per-need mechanism to review. | [design-live.md](design-live.md#the-inspect-service), [design-domains.md](design-domains.md#facets), [design-app-trees.md](design-app-trees.md) |
| **An app is a principal with a session template.** A package selects within the manifest's one `apps` row and never adds; admission is set inclusion, and for the GATT services an app handles also disjointness from the other admitted apps', since a service has one handler, run by the build and the system domain alike. | Users add apps while the security properties stay proven: the separation between principals is the separation between apps, as a user id per app is on Android. | [design-apps.md](design-apps.md#an-app), [design-packaging.md](design-packaging.md#the-apps-row), [design-bluetooth.md](design-bluetooth.md#the-ble-facet) |
| **A file is reached one way, and the boot image holds what the manifest names to run, never a package.** Packages lie in each slot's read-only system partition, served as the `system` tree and checked block by block. | One generic way to reach any file, with integrity in the file rather than its container, after Plan 9 and Fuchsia; installing an app is copying a file. | [design-storage.md](design-storage.md#the-system-tree), [design-packaging.md](design-packaging.md#where-a-package-lies) |
| **The start table says what starts without a person**: the manifest's `start` rows with `/etc/start.conf` over them, each row kept by its own supervisor in the system domain. | One place says when and where everything starts, and a kiosk starts from the boot's own mechanism. | [design-apps.md](design-apps.md#the-start-table) |
| **Code is named by its hash.** | A version is its hash, sharing and rollback fall out, and a changed byte fails the load; a hash gives identity, never trust. | [design-live.md](design-live.md#the-code-store) |
| **Keys stay in the vault**, sealed under a master key per principal that its credential slots wrap; a domain authenticates through a key facet that signs one protocol's input for one purpose. | The user adopted Plan 9's factotum and Argon2id: a compromised network domain gets signatures for one purpose while the grant lives, never a key. | [design-system.md](design-system.md#the-vault) |
| **A program is a port of its session, with the authority it was handed.** It runs in a sub-space of the session's domain, with no domain id, facet or connection; every request is a message on its channel to its handler. | UNIX programs need not be ported to Erlang, and confinement holds by construction: a program's whole world is its session ([Alternatives considered](#alternatives-considered)). | [design-programs.md](design-programs.md#a-program-is-a-port) |
| **A program starts what its `/bin` lists**, and runs a file only through an `rx` grant, which no grant holds with `rw`. | A program never runs what it could rewrite. | [design-programs.md](design-programs.md#what-a-program-can-start) |
| **Descriptors, pipes and signals are `liberx`'s.** | Pipe ends installed by one party make end of stream a consequence of who holds them, and the kernel stays free of POSIX. | [design-programs.md](design-programs.md#descriptors-and-files), [design-pipes.md](design-pipes.md) |
| **Signals and errors have FreeBSD 15.1's numbers**, from `abi/signals.txt` and `abi/errno.txt`; frames carry names, never numbers. | Where UNIX systems differ erXos follows FreeBSD, and programs are ported at the source level, so no binary depends on Linux's numbers. | [design-programs.md](design-programs.md#signal-numbers), [design-programs.md](design-programs.md#the-posix-lite-personality) |
| **A program's tree ends with it**: a program ends with its starter, and a long-running service starts under a supervisor. | Nothing is orphaned. | [design-programs.md](design-programs.md#a-programs-end) |
| **A second tier grows toward QNX**: `fork`, `exec` under the program's anchor, shared libraries, mappings of files and pseudo-terminals; no Linux binary compatibility and no Linux virtual machine. | At least QNX's level, with dynamic libraries. | [design-programs.md](design-programs.md#the-second-tier) |
| **A command shell with rc's language, and toybox.** Every pipe carries text, and each command behaves like FreeBSD's of the same name. | rc's quoting removes the rescanning that makes POSIX shells error-prone, a shell in Erlang reaches the inspector directly, and text pipes keep the commands UNIX's. | [design-shell.md](design-shell.md) |
| **Release consoles log in, and only a login at a secure console line gets the system shell.** | Evaluating in the system domain is as strong as installing code there; tying the facet to a login at a line leaves every route into a session without it by construction. | [design-live.md](design-live.md#the-console) |
| **Lost input is an event, not a byte.** A console UART's driver reports a loss as a message of its own, which every hop carries in order beside the end of input; every other place that drops input, a gap in a tty's numbered input, the tty's bound and the line editor's, makes a loss there; only a program's read turns it into a NUL; a line editor finishes no line of a read that lost input. | A byte value with a second meaning made every consumer of line bytes an exception; an event in order reaches the editor between the keys around the loss, so a damaged command never runs. | [design-live.md](design-live.md#lost-input) |
| **A terminal is a program of its session; a display composites and routes input**, parses no program's output and starts nothing in a session. | As xterm is to X, a terminal in its session needs no console lines or tokens, and the display keeps only an X server's trust. | [design-display.md](design-display.md#the-terminal), [design-display.md](design-display.md#a-displays-session) |
| **A window's pixels are a buffer its client writes; a display composes and interprets nothing.** Draw messages, widget trees and the LVGL program run in the client's session. | One kind of window content serves every renderer, a GPU's included, and the display's parsers stay one-line grammars; a graphics device adds a buffer source or a render service, never a structure. | [design-display.md](design-display.md#windows-and-buffers), [design-display.md](design-display.md#graphics-hardware) |
| **A connection may carry a pixel area**, made by the system domain in the connection's plan at the size the manifest gives. | Pixel memory both sides map must be an object the system domain made; as part of the connection it shares its lifetime, charging and failure paths. | [design-domains.md](design-domains.md#connections), [design-display.md](design-display.md#the-pixel-area) |
| **A kiosk is an app on a display with the single policy**, started by the start row that names the display. | Who holds a screen follows from what starts, not from who opens a window first. | [design-display.md](design-display.md#kiosks-and-glasses), [design-apps.md](design-apps.md#the-start-table) |
| **One width table**, generated from `abi/terminal.txt` and OTP's Unicode data, for `erx_vt`, musl's `wcwidth` and `prim_tty`. | A program, the line editor and the terminal must agree on the cursor after a wide character. | [design-display.md](design-display.md#cells-and-the-grid-state), [design-runtime.md](design-runtime.md#the-c-library-seam) |
| **Text is UTF-8; system identifiers are ASCII; a terminal is a tty.** A program's output reaches its tty unchanged; text labelled with its source is escaped by whatever displays it; `/proc` writes such text already escaped. | Output functions do not touch the data, as on UNIX and QNX, while a label is a claim about a source that a display keeps to one honest line. | [design-live.md](design-live.md#the-tty), [design-live.md](design-live.md#attributed-text), [design-system.md](design-system.md#identifiers) |
| **A boot image is accepted, and the root task started, from one startup plan** that the packer and the kernel both compute with `erx_root_plan`. | The host's check is a prediction the kernel checks, so no root task runs that its image did not pay for. | [design-kernel.md](design-kernel.md#the-startup-plan-and-its-charge-evidence), [design-abi.md](design-abi.md#canonical-source-packing-and-checking) |

## Correct by construction in code

These rules constrain every subsystem's code. Each design document says
how its own code meets them.

**What each kind of check proves.** A build check proves a property of
the code's shape: which code can reach an operation, where a type is
built, that no path exceeds a bound. It cannot prove that code allowed to
perform an operation performs it only when it should: that a funnel
admits only what its domain's export table allows, or that a plan still
matches the state it is applied to, are properties of behaviour, held by state
machines whose invariants are explored exhaustively on the host and by
hostile tests that drive the running system ([Testing and the
oracle](#testing-and-the-oracle)). Fuzzing a parser complements those
tests and replaces neither. Each design document's invariant table names
what holds each invariant, and which of these kinds checks it.

### Functional core, effects at the edge

Every decision that can be a pure function is one. Kernel, `liberx`,
driver and runtime code has two layers:

* **A functional core.** It holds pure decisions, pure state machines that
  return the next action, and plans validated whole before anything is
  applied. The core reads no hardware or global state, builds for the
  host, and is tested there, exhaustively where it is a protocol.
* **A thin layer of effects.** Page-table writes, scheduler effects, MMIO,
  ring writes and message delivery.

Three patterns recur:

* **Plan and apply.** A multi-step operation first computes all its steps
  and charges, and only then applies them, past one point of no return
  after which nothing can fail, or with an undo for each applied step.
  Mapping memory and creating a domain work this way. A plan is bound to
  the state it was computed from: it is applied while the locks it was
  validated under are still held, against reservations it took first, or
  after checking a generation that every change of that state advances,
  so nothing it checked changes unseen before it is applied.
* **State machines that return actions.** The core takes a state and an
  event and returns the next state and the actions to perform; the effect
  layer performs them.
* **Variants, not flags.** A state is one value of an enumeration, or a
  tagged union, never a pair of booleans whose combinations must be kept
  consistent by hand.

Every protocol state machine is explored exhaustively on the host, over
every interleaving of its events up to a stated depth, and checked after
every step for the properties it exists to hold. Each subsystem's design
document names its explored cores and what each is explored for in its
verification section: among them the scheduler's park protocol, the
lane protocol between a producer and a consumer, the domain library's
creation plans, the kernel's capability, deletion and stop cores, the pipe
core, the channel protocol between a program and its handler, the signal
machine of `liberx`, the update state machine and the line discipline.

### One source for the ABI and the hardware

The ABI and hardware sources define the shared representations. Ruby
generators produce every header, accessor and table from them:

* **`abi/erx_abi.txt`** defines the kernel calls (with their argument
  types, rights and executor attributes), rights, status codes, limits and
  every fixed binary layout that is the same on every architecture: the
  shared areas of groups, the boot information page, rings, reader pages,
  records and frames, crash headers, and the in-memory structures devices
  read, such as virtio descriptors and rings.
  `abi/inspection.txt` and `abi/services/<name>.txt` are explicit includes
  of this root schema for inspection and service declarations; their names
  and types are not repeated in another source.
  Each architecture adds `abi/arch/<arch>.txt`, in the same grammar, for
  what differs between architectures: the system-call registers, the saved
  thread state and the tables its MMU and IOMMU read
  ([design-kernel.md](design-kernel.md#the-abi-file)). From them come the
  kernel's decoders, `liberx`'s calls for each backend, the funnel's and
  the domain library's layouts, the device NIF's descriptor layouts, and a
  Ruby module for the packer and the host tool.
* **CMSIS-SVD files** under `hw/svd/` describe every memory-mapped
  register block erXos drives, such as each platform's UARTs, interrupt
  controller, MSI frame, real-time clock and IOMMU, and virtio-mmio
  ([design-platforms.md](design-platforms.md#the-devices-the-kernel-drives)).
  The generator emits typed accessors for C and decoding tables for the
  inspector, and enforces two of the hardware's rules: a register whose
  read has side effects gets no read-modify-write helper, and a write
  sequence the hardware requires is emitted as one function.
* **`hw/sysreg/<arch>.json`** holds the system registers erXos uses on
  each architecture: erXos's access policy for each, and the facts a
  pinned release of the architecture's machine-readable specification
  gives for it. It is a checked-in input, as an SVD file is. An explicit
  refresh command, never the build or `make check`, extracts the facts
  again from the fetched release; the file keeps its publisher's notice,
  its `ORIGIN.md` records the release, and the binding names the source
  and its license
  ([design-arch-aarch64.md](design-arch-aarch64.md#hardware-register-sources)).

[Generated interfaces and representations](design-generation.md) defines
the service stubs and serving paths, inspection builders and projections,
error mappings, log/trace bindings, API reference tables and test
scaffolding derived from these declarations. Startup descriptors are the
checked manifest's own packed arrays, and command catalogs derive from
release metadata; neither adds another configuration source.

Generated files are never checked in: the build generates every output into
`build/gen/` from the inputs, regenerates it whole when an input, a
generator or an output changes, refuses an output that is not ASCII, and
`Erx::Generated.ensure` refuses a repository file at a generated output's path. A test
generates the tree from the same inputs in different places and times and
requires identical bytes. Nobody edits a generated file, hand-packs register bits or copies a constant.

### Chokepoint checks

Every rule of the form "only X may do Y" is enforced by a check that fails
the build on a new site. Every check has a test that seeds a violation and
expects the check to catch it. Such a check proves where Y can be done
from; that X does Y only when it should is held by X's own invariants and
tests.

The rules over erXos's C (the kernel's cores, `liberx`, the Fiasco backend
and the glue) are data, one group per core, in
[`tools/lib/erx/chokepoint_rules/`](../tools/lib/erx/chokepoint_rules/),
evaluated by `make check`; the checks over Erlang call graphs, BEAM files,
manifests and images live with the tools their owning design names. Each
owning design states its rules with their mechanism. The index:

| Rule | Protects | Owner |
| --- | --- | --- |
| the kernel's own rules: capability slots, UTCB and record accessors, memory windows, user addresses, the charging funnel, no FP or SIMD, `musttail`-only recursion, the early console, the firmware mailbox, which after boot sends only rows of the checked platform record, each tag in a closed set and read back at most its window | the kernel's invariants, the reach of firmware requests | [design-kernel.md](design-kernel.md#chokepoint-checks), [design-board-sensors.md](design-board-sensors.md#the-construction-the-firmwares-requests-are-rows-of-the-platform-record) |
| an architecture's terms appear only in its layer and its documents (`make check-arch-terms`) | portability | [design-kernel.md](design-kernel.md#chokepoint-checks) |
| only `liberx` issues kernel calls; only its `fiasco` backend touches Fiasco | the kernel seam | [design-kernel.md](design-kernel.md#chokepoint-checks) |
| only the backend's charging file makes a Fiasco call that charges a quota (`fiasco-charge`) | every refusal of kernel memory is `ERX_ENOMEM`, undone | [design-fiasco.md](design-fiasco.md#the-chokepoint) |
| ERTS imports only `liberx` and its listed names (`make check-runtime-seam`); only the adapter includes `liberx` headers; only listed sites create executors | the runtime seam, R1 | [design-runtime.md](design-runtime.md#what-erts-imports), [design-runtime.md](design-runtime.md#threads-and-synchronisation) |
| only a space's creator installs capabilities into it or copies it; the domain library installs into a domain only through `erx_dom_install` and destroys its budgets only through its ending functions | authority flows outward from the system domain (A1, A7); a domain ends one way | [design-system.md](design-system.md#the-domain-library), [design-system.md](design-system.md#ending-a-domain) |
| only the funnel reads a frame lane's ring; only the three export paths write the export table; privileged helpers take minted handles | D3, D4, message isolation | [design-domains.md](design-domains.md#invariants) |
| only listed OTP modules take a message out of the `{erx_origin, D, Msg}` envelope | D18 | [design-domains.md](design-domains.md#invariants) |
| system-domain code creates atoms only through an allowlist | D5, the system domain's atom table | [design-domains.md](design-domains.md#invariants) |
| a facet enters a domain's table only as an instance of a declared interface | no undeclared way between domains | [design-abi.md](design-abi.md#services-facets-and-their-parameter-schemas), [design-domains.md](design-domains.md#facets) |
| only `erx_ident:new/1` makes system identifiers; only a record's owner builds it | identifiers checked once | [design-system.md](design-system.md#identifiers) |
| the system manifest is read only by its two generated readers, and holds its properties | one checked configuration | [design-system.md](design-system.md#the-manifest) |
| a driver reaches its device only through the device NIF and generated accessors; only the NIF writes a device address | DMA reach, one source for registers | [design-system.md](design-system.md#drivers), [design-runtime.md](design-runtime.md#the-device-nif) |
| only `erx_irq_line` binds or acknowledges a line | a shared line has one owner | [design-shared-devices.md](design-shared-devices.md#invariants) |
| only the pin driver's register modules name a pin controller's registers | a pin controller has one writer | [design-pinctrl.md](design-pinctrl.md#the-pin-driver) |
| only the console's driver writes the console's UART after boot | what the operator types reaches only the system domain | [design-live.md](design-live.md#the-console) |
| the host tool prints guest bytes raw only from `erx console`'s stream | the operator's terminal | [design-live.md](design-live.md#invariants) |
| only the code service writes a hot store or an overlay | code integrity | [design-live.md](design-live.md#the-code-store) |
| only the log service takes the kernel's log ring | L4, one consumer | [design-log.md](design-log.md#invariants) |
| only the clock service sets the wall clock | one setter | [design-time.md](design-time.md#the-nif-and-the-liberx-calls) |
| only `erx_ns` writes the namespace table; a file client sends only through its one request function | one resolver, F2 | [design-files.md](design-files.md#building-binding-and-mounting), [design-files.md](design-files.md#erlang-clients-prim_file-and-erx_file_remote) |
| only a command that declares a service's facet names that service's modules; only `erx_cmd` and the console read a terminal relay | `no_facet` before start; job control's reads | [design-shell.md](design-shell.md#interfaces), [design-shell.md](design-shell.md#the-terminal-relays-protocol) |
| `liberx`'s program layer: the entry macro on every export, no `malloc` or stdio, the event executor takes no kept lock, one channel send, listed obligation makers | signal safety | [design-programs.md](design-programs.md#signals-in-liberx) |
| only `erx_elf_plan` reads executable headers, `erx_image_plan` image-manifest segments, and `erx_exec` maps code | one parser per untrusted format | [design-programs.md](design-programs.md#what-a-program-can-start) |
| only `erx_shm_copy` reads a pipe's pages; no pipe step sees a frame record | the pipe's ring | [design-pipes.md](design-pipes.md#the-ring) |
| no release lets `global` or `pg` span domains | node semantics | [design-runtime.md](design-runtime.md#erlang-visible-behaviour) |
| no generated file is checked in or edited | one source | [One source](#one-source-for-the-abi-and-the-hardware) |
| changed imported files say so; every packed file has known provenance and an allowed license | license conditions | [Licenses and notices](#licenses-and-notices) |
| only the slot writer writes a slot or the record; on a trial boot nothing but the record is written | U4, a bootable system | [design-storage.md](design-storage.md#system-updates) |
| only `liberx`'s root-task entry reads the device-secret page, and only the vault's domain maps the sealing secret | device secrets | [design-system.md](design-system.md#the-vault), [design-platforms.md](design-platforms.md#device-secrets) |
| only storage domains hold partition windows, the network domain the network device, the vault's domain the TPM; the EROFS reader reads only hash-checked blocks | where hostile input is parsed | [design-storage.md](design-storage.md#security), [design-system.md](design-system.md#devices) |

### Bounded stacks

* **The kernel.** Every build proves that each thread's kernel stack,
  8 KiB, holds the thread's deepest path from the call, exception and idle
  entries with the deepest path from the interrupt and asynchronous-error
  entries on top, since an interrupt is taken on the stack of the thread
  it interrupts and handlers never nest, and that the boot and panic
  stacks hold their entries' paths, by combining per-function sizes from
  `-fstack-usage` with the call graph from `llvm-objdump`. Every indirect
  call site lists its targets and every frame has a cap; the build fails
  on a frame over the cap, an indirect call without its listed targets, or
  a cycle through a call not marked `musttail`. The proof is of the build
  it runs on, so every kernel configuration that is built gets its own,
  and its inputs are checked rather than trusted: a function without a
  compiler report fails it, each assembly routine's declared stack use is
  checked against the stack-pointer adjustments in its disassembly, and a
  chokepoint check proves that interrupt handlers never unmask interrupts,
  which is what lets the proof put one interrupt path on top and no more.
  The C17 cores shared with
  Fiasco are under the same rule; Fiasco's inherited C++ is exempt
  ([design-kernel.md](design-kernel.md#stack-proof)).
* **`liberx`'s funnel and channel decoder** parse untrusted input
  iteratively, with explicit stacks, and the same tool's cycle check runs
  on `liberx`, so no input-driven recursion exists in either; the device
  NIF and the domain library parse no untrusted input at all.
* **Storage, network and driver domains** parse media, packets and what
  devices wrote in Erlang processes with `max_heap_size` set, so a parser
  that meets a crafted input ends that process alone; their parsers loop
  over a format's structures and recurse only to bounds the format
  states. The C that remains in them, littlefs behind its NIF
  and any native shim the driver table lists, runs under the same cycle
  check: littlefs states that it has no unbounded recursion, and a
  recursion the check finds in imported code is bounded or removed at
  import.
* **Runtimes** run in user mode with guard pages below every stack, so an
  overflow ends only that domain. ERTS's own recursions are guarded by its
  stack-limit check, and its decoder nests at most one level for what the
  funnel admits ([design-domains.md](design-domains.md#the-funnel)).
* **Every kernel stack has guard pages**, so an overflow the tool cannot
  see is a panic and never a silent corruption.

### Typed addresses and counts

In kernel C code, physical addresses, kernel virtual addresses, user
virtual addresses, image offsets, page numbers, capability values, slot
indices, byte counts and element counts are distinct one-field structures.
Converting one into another goes through a named function. Mixing two
kinds is a compile error instead of a review finding
([design-kernel.md](design-kernel.md#typed-values)). A user virtual
address has no conversion to a pointer at all: it is a place the kernel
maps an object at, translates through a page table for umtx, or reports a
fault at, never memory the kernel loads or stores through, so the rule
that the kernel never dereferences a user address is a fact of its types
([Decisions](#decisions)).

## Security

### Threat model

| Adversary | Can | Cannot |
| --- | --- | --- |
| Code in an Erlang domain | anything inside its domain; spend its own budget and grant; write frames into its lanes, to processes their owners exported to it; use its facets; ring the doorbells it holds; fill a lane and so block its own senders; with `SPACES`, create sub-spaces within its budget and act on them | read or write another domain's memory; reach a process that was not exported to it; tell an unexported process from a dead one; make a receiver hold more than the lane the receiver sized, or wait on it; grow the system domain's atom table beyond its principal's `names` quota; spend another principal's budget or grant; speak for another domain's processes, since the lane names it; act through a facet granted to another domain, whose pid it learnt; act on a space it did not create; make a server, a driver or a connection's peer fault by deleting memory they map or by ending; panic the kernel |
| Code in a sub-space, a session's program included | anything inside the sub-space; use the capabilities its creator handed it; run what its creator mapped executable; ask its creator anything over its channel | anything its creator could not; reach its creator's memory beyond what was mapped into it; make its creator fault; outlive its creator; reach any domain, having no domain id, export table or connection: its channel reaches its creator alone |
| A driver, in Erlang, of a confined device | drive its device through the device NIF; DMA into the pool buffers of memory objects its domain holds | aim its device at memory outside its domain's DMA-mapped objects, since the NIF builds every device address from an object, offset and length it checks, and alone writes one into a register or a descriptor; reach memory outside its space and its IOMMU window |
| A driver of an unconfined device, or the device itself | everything its device's DMA can reach | nothing is enforced: the domain that holds the device is in the trusted base, and a release configuration gives such a device's unit to a domain of its own, so that no domain that parses hostile media or packets holds one |
| The PCIe domain, its PCIe enumerator, or a PCIe device answering the enumerator | read and write every PCIe function's configuration space; enable memory decoding and bus mastering, and so let a function without an IOMMU stream reach any memory by DMA; answer configuration reads as a device likes | give a confined function's DMA any reach, since the IOMMU aborts every stream not bound to a window; reach a BAR or an MSI the device service did not derive for a driver's domain; touch the kernel's state, since configuration space is read in user mode and parsed in Erlang by a bounded parser with a fuzz target |
| The devices domain, or any slow device's driver in it | drive the slow devices, confined or not as each platform has them | reach PCIe configuration space, which only the PCIe domain holds; hold a device that parses hostile media or packets; reach another domain's memory, unless a configuration gives it an unconfined DMA device, which puts it in the trusted base as any holder of one |
| The host-link peer, development build | everything (it holds every facet but the system-shell facet, and the system shell at its `console` line, where `root` is logged in) | nothing more: development builds are for trusted code only |
| The host-link peer, release build | what the configured facets of its session allow | anything else; every byte it sends is checked with the host grammar and decoded safely |
| A device writing shared memory | write the rings and buffers it was given | make a driver, the kernel or a runtime trust what it wrote; every ring entry is validated by its consumer |
| Whoever wrote a storage medium's data partition, or an update image | choose every byte a file system reads from that partition, and what a development build installs through the host link; through a file-system domain that a crafted partition compromises, read and write every principal's files on that partition | make that domain reach any other partition, the vault's partition and its key files included; make the code service load code into any domain, since it writes nothing to a data partition and reads no code from one; change an EROFS image without its hash tree noticing; make a build install an update that its trusted key did not sign, an older one, or, in a release build, a development one |
| Whoever can write the boot medium | where nothing checks the boot image before the kernel runs, as on QEMU `virt`, whose trust root is the host, and on a board without secure boot: anything, the console's prompts included, so a passphrase typed there may be recorded; on a board with secure boot: put into a slot any boot image the board's key signed, an older one included | on a board with secure boot, run code the board's key did not sign; learn a secret from the boot image, which holds none ([design-platforms.md](design-platforms.md#trust-in-the-boot)) |
| Whoever can read a storage medium | read every file on it, the vault's sealed files included; under the vault's `none` backend, guess a principal's passphrase offline against its file, at one Argon2id derivation for each guess, and read the machine keys | under the `device` or `tpm` backend, open any slot away from the board, the machine's included; read a passphrase or a private key without guessing a passphrase; learn a secret from the boot image, which holds none |
| A network peer | send any packet to the network domain; once TCP distribution, TLS or SSH has authenticated it, act with the authority of the service or domain that accepted it | make the network domain do more than fail or drop traffic; reach any domain before it is authenticated, or beyond what the accepting service grants |
| A radio peer in Bluetooth range | send any packet the Bluetooth controller forwards to the Bluetooth domain; connect while a connection slot is free and hold it; use the `open` characteristics of the services the manifest selects; pair during a window opened without a display and so reach `encrypted` characteristics ([design-bluetooth.md](design-bluetooth.md#security)) | make the system domain parse a radio byte, which reaches it only as bytes on the controller's line; reach an `encrypted` characteristic without a bond made in a window, or an `authenticated` one without the passkey the window showed; replace a bond; make the Bluetooth domain spend beyond its declared bounds |
| The Bluetooth controller's firmware, or a compromised Bluetooth domain | everything a radio peer can; read every bond's key, which the controller needs in clear; act as a bonded phone toward the apps whose services the domain serves; the domain also reads the console's lines, passphrases included | reach a device, a partition or a facet beyond the Bluetooth domain's row, which holds no device; the controller reaches only its line, through `data` and the one word of `ctl` |
| The person at the console's UART, present at the machine | in a release build, log in, and then what the session's principal holds, with the system shell when the principal is one the manifest names for it, by default none; as presence at the machine, open a principal's slot made under another sealing backend, and enrol any principal of the system configuration that has no key file, choosing its first passphrase and then acting as it, which, with the vault's partition in hand as well, includes any principal whose file it deletes or replaces with one made under a weaker backend; in a development build, `root`'s session and the system shell, which the console opens at the UART at boot | enrol a principal whose key file it cannot delete; type expressions into the system domain except in the system shell of a login at a secure line; guess passphrases faster than the vault's limits per name and per line allow, or, under its `tpm` backend, than the TPM's lockout allows; inject terminal control sequences into anyone's terminal through text another party supplied |
| A person at a display | use the display's session, which starts without a login. At a desktop: type into its terminals and so hold that principal's authority, the principal's other sessions included, as at a UNIX console that logs a user in automatically, and open sibling terminals and the windows of that session's programs. At a kiosk: use what the app's interface offers, with the app's authority behind it | reach the system shell, which opens only at a login at a secure console line, the UART or the host link; reach a session whose template holds no grant on that display; open the principal's vault keys, enrol a principal, or count as presence at the machine ([design-display.md](design-display.md#a-displays-session)) |
| A compromised display domain | show a false screen, read every byte of its clients' pixel areas, which it maps read-only, record every keystroke it routes and inject input into the windows it serves, as an X11 or Wayland server can: typing into a terminal's window, it has the authority of the shells in the terminals of the session introduced to it and what that session's principal reaches; read and write its display's clipboard where `clipboard` is on | anything beyond: write a client's pixels; read any other memory of a domain, or message a process it was not introduced to; start a program in a session; reach a session not introduced to it; reach the system shell, which no display carries; be attacked by what a client draws or a program writes to a terminal, neither of which it parses ([design-display.md](design-display.md#security)) |
| A domain that serves a display an input device's events | send any input record within the bounds of `record()`, in the binary form of `abi/formats/input.txt`, to that display, as a person at it would: type into and point at every window of the display's session, hidden ones included through the overlapping policy's menu, and so hold that principal's authority, or drive a kiosk's application; type the reserved chord | read what the display shows or what is typed at it; reach a window's pixels; reach a window's files; anything a person at that display cannot do ([design-display.md](design-display.md#input-events)) |
| A native program | anything inside its sub-space; read and write the pipe rings mapped into it; ask its handler for anything within its own table, the descriptors and grants its starter derived for it; start the commands its `/bin` lists, when it holds the right to start commands, each with no more than the program's own authority; signal its own children, through its handler | hold or name a grant's pid, a facet or a domain at all; reach a grant its starter did not derive for it; reach above a grant's root; run a builtin or a function in its session's domain; run a file reached only through `ro` or `rw` grants; reach another session's programs, the inspector or any domain except as a request its handler answers under the session's policy; make a session process wait on it, since the handler reads its channel at its own pace; outlive the program or session that started it |
| A file-protocol client | send requests within the protocol's bounds to the grants it holds; walk a fid to a narrower one; in a session, share an open-file description among its programs; at the host link or on the network, send any bytes, which the 9P2000.L codec decodes within the negotiated `msize` | make a server hold more than the bounds, or the codec more than `msize`; reach above a grant's root, through `..`, a name with `/` or a symbolic link; write through a read-only grant; forge a reply to another client |
| The grantee of a key facet | have its principal's key sign any input of its purpose's protocol role while the grant lives, for any peer, as a daemon holding the key could; receive a token its purpose names | obtain a private key; have the facet sign input of another shape or purpose; delegate the facet, since a domain that learns its pid gets nothing from it |

Assets: the integrity of the kernel; the integrity and availability of
every domain against every other domain; the confidentiality of a domain's
memory against other domains; the bounds of budgets and grants; and the
operator's terminals.

### Trust placement

Only the kernel runs in kernel mode. Everything else, the system domain
included, runs in user mode. Code of unknown provenance runs only in an
address space of its own, a domain or a sub-space that a domain created,
holding only the capabilities it was handed. What each isolation property
depends on:

| Property | Depends on |
| --- | --- |
| a domain's memory, its threads' integrity, and its CPU grant against every other domain | the kernel alone |
| a sub-space's memory and threads against everything but its creator, which built it and may act on it | the kernel alone |
| which processes may signal a domain's processes, and what the domain holds for a sender | the kernel and that domain's own runtime |
| a program's whole world: what it reaches, who signals it, what it reads | the kernel and its session's runtime |
| which domains exist, with which budgets, grants, connections and facets | the kernel and the system domain |
| a principal's private keys, and its passphrase at login | the kernel, the vault's runtime and, for the passphrase in transit, the system domain; against whoever reads the medium, the machine's sealing backend ([design-system.md](design-system.md#the-vault)) |
| a process's state inside its domain | that domain's runtime |

Every domain's isolation, memory, CPU and messages alike, depends on the
kernel and on itself: a frame is validated by the runtime that bears its
consequences, on that runtime's own grant, so there is no party between
two domains whose failure, deadline or quota reaches either. Which
processes may message a domain's processes depends on the kernel and
that domain's own runtime, and on nothing else, as the project's working
rules place it.

The trusted base is therefore the kernel, whose size the kernel's design
estimates ([design-kernel.md](design-kernel.md#requirements)) and Fiasco's
measured size is in the research record
([research](research-hierarchical-scheduling.md#fiasco-sizes)), and the
system domain: its ERTS, built as the interpreter, without BeamAsm, asmjit
or any C++, after the inventory's deletions
([design-runtime.md](design-runtime.md#the-inventory)); `liberx`'s system
layer with the root-task entry and the domain library; and its Erlang
services. Nothing in it writes machine code at run time. A device without
an IOMMU stream adds the domain that holds it, whose driver can aim its
DMA anywhere. The PCIe domain, which holds PCIe configuration space and
nothing else, is in the trusted base whole with its PCIe enumerator:
configuration space turns on any function's bus mastering, which for a
function without a stream reaches all memory, so that domain holds no
other device and runs no other driver
([design-system.md](design-system.md#devices)). The devices domain, which
runs the slow devices' drivers, is outside the trusted base. erXos bounds
the trusted base in three ways:

* **Mechanism is small and native.** Everything every domain's isolation
  depends on for memory and CPU is in the kernel; what a domain's message
  isolation depends on is its own funnel, one C17 library in `liberx`
  under the kernel's construction rules, linked by every runtime.
* **Every input from outside the trusted base crosses one of a few narrow
  funnels**: the kernel's generated call decoder, over registers and UTCB
  fields it reads once; each runtime's funnel on its lanes; each session's
  channel decoder; the host-link deframer and the host grammar; the
  boot-image validator and the system manifest's reader; the drivers'
  Erlang decoders of what devices wrote, over a device NIF that parses
  nothing; the drivers' decoders of client requests, the block driver's
  checking each against the client's windows; the PCIe enumerator's parser
  of configuration space; the file protocol's decoder in `erx_fs`, for the
  trees that services serve, with the line service's one-word `ctl`, which
  moves the bytes of a line's `data` and parses none of them
  ([design-bluetooth.md](design-bluetooth.md#the-controllers-line)), and the 9P2000.L codec at the host link and
  on the network; the update service's manifest decoder,
  which runs only on bytes whose signature it has checked, in a
  development build against the development key the build embeds; the
  slot writer's record check.
* **What untrusted input can reach is fuzzed and checked differentially**:
  the funnel against `binary_to_term/1`, and every parser with its own
  fuzz target.

### Why no verifier

ERTS loads code without verifying it and states that loaded code is fully
trusted ([research](research-erts-internals.md#loader-trust)). erXos does
not change that. Untrusted code runs only in its own domain, where a
malicious module can corrupt only that domain's runtime, and the hardware
enforces the domain's boundary. A verifier in the trusted base would
itself be attack surface, as the eBPF verifier's history shows
([research](research-prior-art.md#other-systems)). The system domain loads
code only from its release and through the install facet
([design-runtime.md](design-runtime.md#code-in-the-system-domain)).

### Machine code

No mapping is ever writable and executable at once, and the kernel writes
no machine code. BeamAsm runs only in user-mode runtimes, in spaces the
system domain's domain library created with JIT objects allowed, and
writes code through a writable view of a memory object that another view
executes ([design-runtime.md](design-runtime.md#beamasm)). The domain
library allows JIT objects exactly in the spaces of domains whose image
the packer marked as making them: the BeamAsm runtime image. The system
domain's image is the interpreter, which the packer does not mark, so
the root task's space allows no JIT object, holds no view that is
writable before it is executable, and links neither asmjit nor C++; and no
program's sub-space is a JIT space
([design-programs.md](design-programs.md#invariants) P10). So the
right to make code follows from the image, never from a request
([design-kernel.md](design-kernel.md#image-manifests)). A sub-space allows
JIT objects only when its creator's space does, and runs only code its
creator could map executable, so it never makes or runs code its creator
could not. The writable view stays inside the domain whose code it is, so
it gives that domain nothing it did not have.

### Authority

* Kernel objects are reached through capabilities with generations and
  rights that only shrink. A capability enters a table only at a
  rendezvous, into slots the receiving space reserved, or from the space's
  creator: the system domain's domain library for a domain, and the
  creating domain for a sub-space, a session's port driver for a program's
  sub-space among them. So authority flows outwards from the system
  domain's table and no domain installs anything into another domain's
  table; since no domain holds a gate of another, no rendezvous joins two
  domains and no capability passes between them
  ([design-system.md](design-system.md#authority)).
* A pid of another domain carries no authority by itself. A domain's
  export table, which its own runtime alone writes, says which of its
  processes each peer domain may message, link to, monitor, exit or spawn
  into, and with which rights. It gains an entry in exactly three ways:
  the owner encodes one of its own pids or aliases into a frame for that
  peer, which is stock Erlang's handing out of a name; a peer spawns a
  process into the domain, for the spawned pid toward the spawner; or a
  process calls the explicit export function on one of its own pids or
  aliases. A pid entry ends with its process and an alias entry with the
  alias's deactivation, under OTP's own alias rules, so a stale pid names
  nothing; the revocable name is an alias, as in stock OTP; and an owner
  can export with fewer rights, never more, and no peer can widen one.
  Pids of other domains in a payload remain unchanged data. Privileged
  service helpers require handles a facet minted from its own scope,
  never authority inferred from a bare payload pid
  ([design-domains.md](design-domains.md#exports),
  [design-domains.md](design-domains.md#authority)). References have
  structural uniqueness within a boot and a quantified cryptographic
  guessing bound, not an unconditional claim that guessing is impossible
  ([design-runtime.md](design-runtime.md#unguessable-references)).
* Services are reached through facets, processes that each stand for one
  grant to one grantee domain. A facet acts only
  for its grantee, the domain whose lane its requests arrive on, so
  passing a facet's pid delegates nothing. A program has no facets:
  anything beyond its session is a request to its handler, which the
  session's policy answers. Revocation is a facet's exit; nothing is
  admitted after it, and nothing done before it is undone
  ([design-domains.md](design-domains.md#facets)).

### Resource limits

* **Memory.** Every page and every kernel object is charged to a budget,
  carved from its parent's with a guarantee no other budget can take and
  a cap up to which it spends what its ancestors have promised to no
  one; a domain's budgets are walls, with cap fixed equal to guarantee,
  so a domain over its budget gets allocation failures and ends only
  itself, and no
  domain's charge is ever counted against another's; a program's cap can
  be its session's whole pool for programs, so a program is refused only
  when that pool is full, as a QNX process is at the system's; and
  destroying a budget frees everything
  charged to it at once, so a domain's end returns all its memory with
  nothing left to drain.
* **CPU.** Every thread is in a group; a group over its quota waits for
  its next period, whatever its runtime reports; no thread ever runs on
  another group's time, so a service's work is charged to the service's
  own group, whose grant policy caps and sizes for the domains it serves;
  finishing a stopped call runs outside every quota within each CPU's
  finishing share and is counted as finishing time on the stopped
  threads' own groups, apart from their usage, and reclaiming a stopped
  space is charged to the caller as any call is ([design-scheduler.md](design-scheduler.md#service-work),
  [design-scheduler.md](design-scheduler.md#pick-and-dispatch)).
* **Messages.** A sender whose lane is full waits in its own runtime, as a
  sender to a busy distribution connection does, and nobody else waits; a
  receiver drains its lanes at its own pace and spends its own CPU
  validating what it drains; each lane's ring is charged to the
  connection's child budget of the outer budget of the domain that reads
  it, both lanes of a domain's system connection to that domain's, and
  sized by the reader's policy, and the connections a domain has are
  those the system domain made for it
  ([design-domains.md](design-domains.md#connections)).

The lane the system domain reads from a domain is charged to the domain's
outer budget, through its child budget for the system connection, and
sized by the system manifest's `system_lane`. Everything else another
domain can make the system domain hold is a sum fixed when the domain is
admitted, since an allocation failure in the system domain's runtime is a
reset: one open record from that lane, in a buffer
that grows as its bytes arrive, up to the system domain's `max_frame`, the
largest request a grant may name; its queue to the domain, up to the
system manifest's `system_queue`, past which a message is dropped and any
other signal ends the connection, which ends the domain; what it holds
because of the domain's processes, up to its own `peer_held`, which is
small; and the facet processes it holds
for the domain, each with `max_heap_size` set and off-heap binaries
counted. The domain service admits a domain only when the system domain's
budget holds that sum for every admitted domain
([design-system.md](design-system.md#resource-policy),
[design-domains.md](design-domains.md#flow-control)). Lazy decode makes an
untaken frame cost its bytes and nothing more, and one commit funnel for
the system domain's shared state leaves nothing half-done when a facet
gives up on a request. A spent client's requests wait in its own lane and
its own facet, and the system domain's replies travel within the lanes the
client reads, so the system domain is neither exhausted nor stalled by
another domain.

### Residual risks

* **A drive's volumes are a stranger's bytes.** The media domain parses
  a drive's table and its FAT and EROFS volumes in Erlang, each volume
  in a process of its own under a memory bound. A crafted volume can
  fail its mount, serve wrong data from itself or damage itself, and a
  crafted table can refuse its medium. Development builds and test
  images also serve littlefs volumes, with littlefs's C in a sub-space
  per volume, where a memory error a volume can steer reaches its own
  volume through its owner's checks and, like any sub-space's code, the
  kernel's calls and the CPU; no release serves them
  ([design-drives.md](design-drives.md#security)). A
  drive's EROFS image is read with no hash tree: E1 binds the system's
  own images, not a stranger's
  ([design-storage.md](design-storage.md#invariants)).
* **Speculative and cache side channels** between domains sharing a CPU,
  across CPUs through the read-only pages domains share, such as a runtime
  image's code, since user mode may clean caches by address, which JIT
  compilers need, and any channel within a domain. The domain is the
  confidentiality boundary; the kernel maps no secret of its own into user
  mode, and a domain maps only its own release's files. Two secrets live
  in user mode: the device secret, which the kernel derives at boot and
  hands to the root task on a page only it holds, mapped by `liberx`'s
  root-task entry until it has derived the sealing secret and closed the
  page's capability, before ERTS starts; and the sealing secret, on a page
  whose one capability the domain library keeps and which, once the
  root-task entry has written it, only the vault's domain maps. So the
  root-task entry and
  the vault's runtime are inside this residual. On the boards' cores,
  speculative reads from user mode that the kernel's mitigations do not
  cover remain ([design-kernel.md](design-kernel.md#security)).
* **Timing channels.** A domain can learn about other domains' activity
  from timing alone: how fast its calls return, how often its executors
  run, how long its frames wait in a lane. The kernel shows a group's
  state only to whoever maps its areas, so nothing but timing leaks
  ([design-scheduler.md](design-scheduler.md#security),
  [design-kernel.md](design-kernel.md#security)).
* **Unconfined DMA** on QEMU `virt`, whose IOMMU translates only PCIe
  devices, and on the Raspberry Pi boards: no IOMMU is described for the
  Pi 4, and the Pi 5's tree assigns its IOMMUs to neither its Ethernet nor
  its USB
  ([research](research-boards-storage.md#raspberry-pi-5-bcm2712-and-rp1)).
  Virtio-pci behind the IOMMU for confined drivers on QEMU, on its PCIe
  bridge's root bus alone, the one bus whose requester ids the fabric
  fixes, so that no device can present another's
  ([design-kernel.md](design-kernel.md#dma-and-the-iommu)); in release
  builds, unconfined devices given to drivers only when the system
  configuration names them, and contiguous memory only when the boot image
  allows it, so a release image for a Pi says that it does. Each
  platform's DMA contract states what its bus masters can reach and which
  of its entries are unconfirmed
  ([design-platforms.md](design-platforms.md#dma)); QEMU `virt` enables its
  IOMMU explicitly through that platform's machine configuration.
* **An asynchronous error reported too late to attribute**, from a posted
  write, is contained at the device that the platform's error records
  name, which is reset, its memory not reused before the reset is done;
  where no record names one, it is
  presumed to be the running thread's, which may belong to a domain other
  than the one whose device caused it, and the fault record says the
  attribution is presumed. An error the processor reports as uncontainable
  or unrecoverable panics the kernel, the one way a device can panic it
  ([design-kernel.md](design-kernel.md#interrupts-time-and-entropy)).
  Each board's contract says which error records it has, and each board
  gets an error-injection test before drivers run on it.
* **MSIs through an MSI frame** do not identify the writer, so a device
  that can write the frame can raise any of its lines: a spurious
  interrupt to another driver, which validates its rings anyway. An
  interrupt controller with per-device MSI translation closes it on
  boards that have one
  ([design-kernel.md](design-kernel.md#interrupts-time-and-entropy)).
* **ASID rollovers forced by sub-spaces.** A domain holding `SPACES` that
  creates and runs sub-spaces quickly can force rollovers of the address
  space tags, each an invalidation of every CPU's TLB, at most about once
  a second for each CPU that creates spaces, an estimate
  ([design-kernel.md](design-kernel.md#security)).
* **A PCIe link that drops during a configuration access** on the
  Raspberry Pi 5 aborts the PCIe enumerator's register read inside the
  device NIF: a fault that ends the PCIe domain, which the system
  domain restarts, or, if the abort arrives asynchronously, an error
  charged to whichever thread runs then
  ([design-platforms.md](design-platforms.md#pcie-bridges)).
* **A fault in the system domain resets the machine**, since it is the
  root task and every domain's space is its child: nothing is left to
  reconcile without it, so there is no recovery protocol, and the kernel
  writes a crash record first. Its services are supervised Erlang, so a
  bug in a policy service restarts that process. The domain service alone
  is a significant child, whose end ends the system domain, so it is never
  restarted and keeps no state for a successor; otherwise only a fault of
  its runtime, its halt or a missed watchdog reaches the reset, and the
  watchdog is petted only while the domain service and the device service
  answer. More than three
  unordered ends in a row boot the system release's rescue
  configuration, so a fault at every boot does not loop forever
  ([design-system.md](design-system.md#boot)). The system domain runs the
  interpreter image, the same ERTS as every other domain's but for the
  JIT, and every domain runs the interpreter in deterministic mode, so
  its runtime is exercised beyond the system domain
  ([design-system.md](design-system.md#the-root-task)).
* **The funnel's correctness** is every runtime's message isolation. It
  is one small C17 library, fuzzed, checked differentially against
  `binary_to_term/1` and tested with hostile peers; a defect in it ends
  the receiving runtime, not a third party
  ([design-domains.md](design-domains.md#the-funnel)).
* **A passed object dies with its giver's budget.** An object another
  domain holds or maps dies when the budget that paid for it is destroyed,
  at the giver's end included: the holder's capabilities fail the lookup
  and its mappings fault. No domain holds an IPC gate of another domain,
  so memory crosses a domain boundary only through objects the system
  domain created and charged to an outer budget, which outlives every
  party that maps it, and no domain maps memory a peer's end deletes.
  Inside one domain's budget tree, what a domain and its sub-spaces pass
  each other still dies with its giver's budget, and a holder that must
  keep something charges it to its own budget
  ([design-kernel.md](design-kernel.md#security),
  [design-system.md](design-system.md#security)).
* **Pipes and terminals trust those who share them.** A pipe's co-readers
  trust each other with their shared stream
  ([design-pipes.md](design-pipes.md#security)); a program on a tty can
  send the terminal any control sequence, a fake prompt included, as on
  UNIX and over `ssh` ([design-live.md](design-live.md#security)); and a session's programs share their session's
  handler and the session's lanes, so a few hostile programs of one
  session can delay their siblings' requests
  ([design-programs.md](design-programs.md#security)). At a file server
  they share, as well, the three quarters of each root grant's fid pool
  that derived and passed grants draw from, so one program can make its
  siblings' opens there fail with `emfile` until the user stops it; and
  their shared mappings draw on the session's mapping quota, 64 MiB by
  default, set by `erx_policy`, so one program can make its siblings'
  shared mappings fail with `enomem`
  ([design-files.md](design-files.md#security)).
* **A receiver that stops draining its lane suspends the processes that
  send to it**, as a busy distribution connection does, a server's replies
  to it included; only that connection is affected, and services shared by
  distrusting domains reply through facets or with `nosuspend`
  ([design-domains.md](design-domains.md#security)).
* **A saturated service slows every client of it together**, since it
  runs on one capped grant and schedules its clients fairly within it;
  policy sizes the grant for the domains the service serves, and a client
  whose work grows with its input runs that work in its own domain
  ([design-system.md](design-system.md#resource-policy)). The network
  domain is such a service at the packet level too: one interface process
  decodes every frame of its interface before any client's credit or
  grant applies, so a flood faster than it decodes makes the driver drop
  frames for every client alike
  ([design-network-stack.md](design-network-stack.md#residuals)).
* **The system domain's size.** A defect in its ERTS or services acts with
  its authority over policy, though not over other domains' memory, and a
  fault of its runtime resets the machine. Facets confine what clients
  can ask of it.
* **Generated code without branch protection** in a domain that runs the
  JIT, because BeamAsm emits no landing pads; the system domain runs the
  interpreter and so runs no generated code
  ([design-runtime.md](design-runtime.md#running-erlang-code-the-options)).
* **Fiasco is hardened only as [design-fiasco.md](design-fiasco.md)
  lists.** Development builds run trusted code only; the security closure
  has two forms, 0.2's on Fiasco and M11's on erXos's kernel, and what
  Fiasco lacks against erXos's kernel is a published downside
  ([design-fiasco.md](design-fiasco.md#downsides-against-erxoss-kernel)).
* **Closed firmware, and verified boot only where secure boot is on.**
  The boards' firmware is Broadcom's binary: it loads the kernel and stays
  resident for the machine's life, with access to all memory. The firmware
  that starts CPUs and ends the machine stays resident on both boards,
  more privileged than the kernel. Both are trusted as any machine trusts
  its firmware, and so is every bus master the loader started and left
  running, until its driver resets it: erXos proves no master stopped at
  its entry, installs a device's buffers and descriptors only after its
  reset, and leaves a master it never drives as the loader left it; what
  such a master writes before its reset, memory the kernel has handed
  out included, is a [Medium] security residual
  ([design-platforms.md](design-platforms.md#dma)). The Pi 5's firmware, its resident part included, and both
  boards' bootloaders live in the board's EEPROM, outside the slots, so an
  update does not change them
  ([design-platforms.md](design-platforms.md#firmware)). What checks a
  boot is the platform's
  ([design-platforms.md](design-platforms.md#trust-in-the-boot)): on QEMU
  `virt` the host, and on a board the firmware's secure boot, which
  checks each slot's boot image, and through it the hashes that pin the
  system partition's files, against the board's key. Where nothing checks it, inside a QEMU
  guest and on a board without secure boot, whoever can write the boot
  medium controls the machine, its console's prompts included, so console
  enrolment is only as trustworthy as the medium. Even with secure boot no
  firmware refuses an older signed image: the Pi 4's has no anti-rollback,
  the Pi 5's documents describe none, and erXos's security version guards
  only what an update installs
  ([design-storage.md](design-storage.md#system-updates)).
* **No domain loads code from a data partition by itself.** The code
  service keeps overlays, hot stores and installs in memory only, so code
  reaches a domain only through a facet's explicit load, whose bytes may
  have been read from a file anywhere and are checked by hash, or through
  a system update
  ([design-live.md](design-live.md#the-code-store)).
* **Key facets and tokens.** A key facet authorizes at the level of its
  purpose's protocol role: it signs its purpose's input for its grantee
  while the grant lives, for any peer, since the vault sees only digests
  of the session; restricting a grant to destinations would need
  authenticated evidence of the session, which no grant asks for. The
  vault's runtime, its ERTS, its NIFs and OpenSSL, is inside every key's
  security boundary. Tokens and passwords leave the vault whole, to their
  grantee, and are logged; a passphrase passes through the system domain's
  principal service on its way to the vault at login; under the vault's
  `none` backend, machine keys are as readable as the medium
  ([design-system.md](design-system.md#security)).
* **Forged and rolled-back logins.** Under the vault's `none` backend,
  whoever can write the vault's partition can replace a principal's file
  with one sealed under a passphrase of its choosing, which the vault
  accepts, since the file is its only check, and so act as any principal,
  one that holds the install facet or that the manifest names for the
  system shell included; under `device` or `tpm`, a slot made away from
  the board does not open, and a file made under `none` opens only at the
  console's UART, as every slot made under another backend than the
  machine's does. Under every backend it can put back an older copy of a
  file, which opens with the passphrase it was sealed under, and, if it
  can also reach the console's UART, delete a principal's file and enrol
  that principal afresh, which the vault cannot
  tell from a principal that never enrolled; the principal's keys are lost
  with the file. The partition is the vault's own,
  written only by a storage domain whose only client is the vault, so each
  of these takes the medium in hand
  ([design-system.md](design-system.md#security)).
* **The TPM's storage key** is trusted on first use: the vault records
  its name when it makes the machine's file and refuses another at every
  later start, so a TPM driver or bus interposer that substitutes a key
  at that first moment, or that can also rewrite the vault's partition,
  sees the authorization values and secrets of the slots opened through
  it ([design-system.md](design-system.md#the-vault)).
* **littlefs serves the vault's partition** until erXos's F2FS, as it
  serves the data partition, a stopgap: a crafted partition can end the
  vault's storage domain, which leaves the vault `unavailable`, and a
  defect in littlefs can lose a key file. A crafted partition that only
  damages files reveals no key, since every file is sealed under keys
  that storage domain never holds
  ([design-storage.md](design-storage.md#read-write-storage)). 0.2 ships
  littlefs as a NIF, so a memory defect in littlefs runs in a storage
  domain that holds an unconfined DMA-capable block device, and so
  reaches the whole machine, live keys included, a published downside of
  its [release contract](design-stopgap.md#release-contract); the
  storage domain's sub-space port, littlefs's target placement, confines
  it to the port and the volume the port holds.
* **Offline guessing of passphrases.** Each principal's file, which is
  also the vault's only check of its passphrase, lives on the vault's
  partition, which only the vault's storage domain serves and nothing
  encrypts. How far whoever reads the medium gets depends on the machine's
  sealing backend: under `none`, guessing is offline, slowed only by
  Argon2id; under `device`, it needs the board's key as well, which code
  in kernel mode on the board can read, as can whoever boots other code on
  a board without secure boot; under `tpm`, every guess goes through the
  TPM, at the rate its lockout allows, which no one can reset, since its
  authorization is kept nowhere. Online guessing is bounded by the vault's
  limits per name and per terminal, and the boot image holds no secret
  ([design-system.md](design-system.md#the-vault)).
* **Implicit bidirectional reordering** of displayed text is not escaped,
  so right-to-left letters can move neutral characters around them on a
  terminal ([design-live.md](design-live.md#attributed-text)).
* **Domain ids are never reused within a boot**, and the id space is
  finite: the domain service allocates them and refuses a creation once
  they run out, and a reboot restarts them. Programs take no id, so only
  domain creations, which policy admits, spend them
  ([design-domains.md](design-domains.md#domain-ids-pids-and-references)).
* **A medium that loses acknowledged writes**, as some SD cards do,
  defeats any file system and can damage the one-sector boot-selection
  record. The record is written only at a commit, when both slots are
  complete, each board's port checks what its firmware does with an
  unreadable record, and a torn record needs an installation
  ([design-storage.md](design-storage.md#system-updates)).
* **Unauthenticated network time.** The NTP server ntpd uses, or anyone
  on the path to it, sets the wall clock to any time after the release's
  floor date at a cold start and then walks it by up to 1000 s every two
  polls; the step thresholds filter single corrections and bound nothing
  over time, so certificate validity and file and log times follow the
  server. Root's `ntpctl step` sets the clock through `set`, so the
  server it takes the time from, or anyone on the path to it, sets any time, below the floor too when
  root names the server and past the floor from ntpd's last sample, which
  then holds against ntpd for the boot
  ([design-time.md](design-time.md#setting-the-clock-from-a-server-once)).
  Network Time Security is the remedy
  ([design-time.md](design-time.md#security)).

## Signature experiences

What a person can do on erXos that no conventional system offers;
[plan.md](plan.md) makes each one a milestone's demonstration:

* **The shell is the operating system.** Boot to an Erlang shell on the
  serial console, the system shell of a development build or a session
  after a login, in which `erx:ps()` lists every process of every domain
  its inspect facet covers, each pid showing its domain, and any of them
  can be monitored, linked or traced from there.
* **The machine is an object.** `erx:i()` shows CPUs, threads, groups,
  domains, budgets and processes as live records, each value marked with
  who reported it; `erx:source(Pid)` opens the line a process is
  executing; `erx watch` on the Mac recompiles and hot-loads a module into
  the running machine.
* **Two schedulers you can watch as one.** One timeline shows the kernel's
  decisions (which executor ran where, parked, throttled, preempted)
  beside each runtime's (which process ran on that executor), and a
  service's statistics show which client's requests its time went to.
* **Native code on the same grants.** A session's programs, C in
  sub-spaces, and the ERTS domains around them share the machine by the
  same groups and grants; the kernel knows neither.
* **A driver is a process.** Kill the network driver's process
  mid-transfer, from the shell, as any process; its supervisor restarts
  it, the device is reset, and the shell never noticed.
* **A wall around some processes.** From the shell, create a domain, spawn
  into it with a link, and crash it: the link delivers
  `{domain_down, D, crash}`. Inside the domain, forge any pid: nothing
  happens, exactly as if it were dead.
* **Users without a container runtime.** A user logs in and gets a domain
  with quotas and a CPU share; exhausting either ends or slows only that
  domain.
* **UNIX tools over live Erlang state.** In the command shell,
  `ps -o pid,rss,comm | sort -rn -k2 | head` lists the session's
  Erlang processes and programs together in FreeBSD's text, `-` where
  erXos does not measure a value, and `grep -r error /proc/domains |
  wc -l` reads the inspector's state as files; `awk` and toybox's other
  applets join the same pipes, each a port of the session in a sub-space
  that reaches nothing but its channel and the grants its starter
  derived for it.

## Kernel

erXos's kernel is a capability microkernel of its own, written in C17 on
the design and know-how of Fiasco ([design-kernel.md](design-kernel.md)).
It keeps Fiasco's model wherever erXos needs nothing else, and records
every departure, with its reason and what Fiasco's way would lose, in its
[L4 lineage](design-kernel.md#l4-lineage) ledger. What it keeps:

* objects reached through capabilities held in a table per space, flat as
  in Fiasco's object space, deleted for every holder by a holder of the
  delete right and freed after an RCU grace period, each with Fiasco's two
  locks, the capability lock and the existence lock;
* spaces created by any holder of a budget with `SPACES`, as any holder
  of a factory creates tasks;
* a kernel stack per thread in a preemptible kernel with helping locks,
  where a call, once started, runs to its end;
* IPC gates bound to one thread, with labels, an open wait and an
  implicit reply, and messages in each thread's UTCB;
* IRQ objects that hardware lines, MSIs and software trigger alike;
* the subset of the vCPU interface that delivers signals to workers;
* PCIe enumerated in user mode, as in L4Re;
* one root task that the kernel starts with the root capabilities.

The departures the rest of this document leans on: memory objects with
ceilings in place of a mapping database, and no pager, so every fault
resolves from its object or ends the thread, and an access to deleted
memory faults to the space's fault gate; a kernel that never loads or
stores through an address in a domain's memory; budgets that, as EROS's
space banks do, delete every object charged to them; capabilities with
generations in slots the kernel assigns; rights per type, with pass sets;
spaces with parents, and holds that keep a space's threads from returning
to user mode while every call they started runs to its end; groups with
grants and no donation; consoles driven in Erlang in the system domain,
the kernel keeping only an early console for its own log; a watchdog the
root task pets; and a root task whose fault is a machine reset after a
crash record, rather than a kernel panic.

**Fiasco.** A modified Fiasco runs near-stock under Phase 1 and 1b of the
plan and is the first release's kernel; `liberx`'s Fiasco backend
implements the interface over Fiasco's own capabilities, factories, IRQ
objects, DMA spaces and MSIs, in user mode, with the root creating and
placing every object and nothing of erXos's kernel semantics inside
Fiasco. Its call table gives each call's result on Fiasco, and what Fiasco
lacks is a list of downsides against erXos's kernel
([design-fiasco.md](design-fiasco.md)). Each subsystem's design says what
it does on Fiasco; wherever this document says Phase 1's system, it means
Phase 1 and 1b's. After the first release, Fiasco is improved to a
stated point and gate GF decides whether erXos builds its own kernel
([plan.md](plan.md#track-f-fiasco-improved-to-the-decision)); if it
does, erXos's kernel replaces Fiasco once it runs the first release's
system, gated on the conformance suite and Phase 1's tests, after a
pilot of the capability table and budgets calibrates the effort
([design-kernel.md](design-kernel.md#risks-and-open-questions)). Both
kernels may stay supported for a while before Fiasco leaves, each a
backend behind the same kernel interface.

## C library

**musl 1.2.6 is the C library of every runtime and native program.** It
lives in the tree as erXos's code; its Linux system-call layer is replaced
by `liberx`, its signals and processes give way to `liberx`'s personality,
with FreeBSD's signal numbers, and its dynamic linker lives on, adapted,
as the loader of executables and shared libraries
([design-runtime.md](design-runtime.md#the-c-library-seam),
[design-programs.md](design-programs.md#the-second-tier)). The kernel uses
no C library: it has its own freestanding primitives
([style.md](style.md)). BeamAsm's C++ runtime, libc++ and libc++abi from
LLVM 23.1.x without exceptions, RTTI or localisation, sits on the same
seam in runtimes that run the JIT. Float conversion is erXos's own, so
float text never depends on the library. The comparison of candidates that
chose musl is in [research-c-library.md](research-c-library.md); picolibc
fit best when dependencies were to be used unmodified, and musl's
completeness and exact conversions won once every dependency could be
modified.

## The JIT

ERTS comes as three runtime images over two builds. The BeamAsm image runs in every ordinary
domain by default, storage and network included, in user mode, with its
code in memory objects mapped writable at one address and executable at
another in spaces allowed JIT objects; ERTS's code barrier makes every
executor issue an instruction barrier before new code is reachable. The
system image, of the interpreter build, runs the system domain, which does
bounded control only, so no JIT object, no view that is writable before it
is executable and no C++ exists in the trusted base; the interpreter image,
the same build with OpenSSL, runs command domains, and in deterministic
mode every domain but the system domain. The roster of alternatives (interpreter only, ahead-of-time
translation on the host, an ahead-of-time image with hot-loaded code
interpreted) is kept with the triggers for re-evaluating it
([design-runtime.md](design-runtime.md#running-erlang-code-the-options)).

## Drivers and DMA

A driver is an Erlang process under a supervisor, in a domain that holds
its device's capabilities; the C under it is the device NIF's, the thin
device shim, with no parsing ([design-system.md](design-system.md#drivers)).
The domain holds the device as kernel capabilities: MMIO windows are
memory objects mapped with device attributes, a line's IRQ object is bound
to the domain's group, and DMA is confined behind the IOMMU or declared
unconfined, which puts the domain and its device in the trusted base.
Which domain holds a device is configuration: each device goes to exactly
one domain named by the system manifest ([Decisions](#decisions),
[design-system.md](design-system.md#devices)).

The driver reaches its device through one module, `erx_device`
([design-runtime.md](design-runtime.md#the-device-nif)): registers by name
through the accessors generated from the CMSIS-SVD files, buffers from a
pool in a DMA-mapped memory object, descriptors and interrupt
acknowledgement. The rules that bound what a driver can do:

* **The NIF alone writes a device address**, built from a memory object
  the domain holds, an offset and a length, checked; no register write or
  ring entry from Erlang can aim a device elsewhere.
* **Pools and queues belong to the device's record**, never to a driver
  process, and are let go only after the device's reset, so a driver's
  crash frees nothing its device may still hold; an unconfined device's
  memory is the system domain's for the boot and never freed.
* **The NIF parses nothing a device wrote.** Erlang does, in a supervised
  process; a received buffer's bytes are copied into a fresh binary, so no
  binary aliases memory a device can write.
* **Interrupts are messages.** The IRQ object is bound to the domain's
  group, the owning process gets a message and acknowledges through the
  NIF; no dirty scheduler blocks in an interrupt wait. Devices that share a
  register page or an interrupt line are one unit, given whole to one
  domain ([design-shared-devices.md](design-shared-devices.md)).
* **Every delivery is a hint to look.** A doorbell or an interrupt makes
  its sink read the ring or the device's status, so a late, repeated or
  stray delivery costs one look.

**Deadlines in state.** Time follows the same rule. Every pure protocol
core with a timeout keeps each deadline as an absolute time inside the
state it guards, takes the current time as an input to every step, and
answers its earliest deadline through a pure `next_deadline/1`
(`infinity` when it has none). Only the process at its edge reads the
clock: it keeps one wake-up timer no later than that deadline, and the
timer's message is a hint to step the core with the current time, never
an event in itself. Leaving a state drops its deadline, so nothing is
cancelled and no stale timer message needs recognising; and the core's
tests treat the clock as one more input
([style.md](style.md#functional-core),
[design-network-stack.md](design-network-stack.md#deadlines-not-timers)).

Every piece of native driver code other than the device NIF is a native
shim, a row of the driver table, and without the row none runs
([design-system.md](design-system.md#the-driver-table)). A native shim
runs as a sub-space port of the driver's domain, so for a confined device
its bugs cannot touch the Erlang heap; for an unconfined device it is in
the trusted base, as the device is. A native driver exists only where
gate G9's measurement shows that an Erlang driver misses the device's
timing or costs more than a stated fraction of its throughput.
Interrupt-to-handler latency passes through the runtime's scheduler, so
G9 decides batching per device class; and one ERTS instance per driver
domain is why devices are grouped by configuration.

On QEMU `virt` the IOMMU translates only PCIe devices, so confined drivers
use virtio-pci and its MSIs; virtio-mmio drivers are unconfined. The first
drivers are virtio console, block and network, after sDDF's split between
a driver, which touches registers and rings and parses nothing from
clients, and the policy beside it ([Dependencies](#dependencies)). The
PCIe enumerator is an Erlang process in the PCIe domain, which holds the
configuration window and nothing else and so is in the trusted base whole
([design-pcie.md](design-pcie.md)). The console's UART and the host
link's belong to their drivers in the system domain, so what the operator
types reaches only the system domain and the session connected to the
console; the manifest names both by device-tree path, and the device
service refuses at boot a console path other than `/chosen/stdout-path`'s.
The kernel keeps only an early console for its own log
([design-kernel.md](design-kernel.md#console-log-and-panic)) and the
devices of `hw/kernel_devices.txt`. Release builds give a domain an
unconfined device only when the system manifest names it, and give each
such device a domain of its own.

## Storage and networking

Storage and networking are services in Erlang domains of their own, with
the block and network drivers as supervised processes of the same
domains, reached through facets like every other service, so a file
system or a network stack that fails, or
is attacked through its medium or its packets, fails within its domain,
and inside it within the process that met the input. The medium's
layout and formats, the storage services and system updates are
[design-storage.md](design-storage.md), and erXos's F2FS, the main
read-write file system, is [design-f2fs.md](design-f2fs.md). The network
service's choices
follow; they bound its design document, which
[plan.md](plan.md#1b-g-networking-on-qemu) schedules
([research](research-boards-storage.md#network-stacks)).

### Networking

The network service runs erXos's own TCP/IP stack, written in Erlang, in
the network domain: Ethernet, ARP and IPv6 neighbour discovery, IPv4 and
IPv6, ICMP, UDP and TCP. Every connection is a process of the network
domain, so a connection can be inspected, traced, supervised and upgraded
live like any other process. A malformed packet corrupts no memory and
crashes nothing: every decoder is total and refuses what it cannot parse,
the interface process drops the frame and keeps its state, and only a
socket whose own step fails ends, alone. Erlang does the work done
once per packet: decoding headers by binary matching, the protocols'
state machines and timers, and the demultiplexing to connections. The
work done once per byte stays in C primitives of the runtime: the
Internet checksum, unless the network driver offloads it, the SipHash
that keys initial sequence numbers and SYN cookies, and the moves
between the driver's rings and binaries, a received frame copied once out
of its buffer into a binary of the network domain's own
([design-runtime.md](design-runtime.md#per-byte-primitives)).

The unit of TCP work is a run, one header over a range of payload cut at
one segment size: the copy each medium needs anyway cuts a run into
frames, and received in-order segments of one flow are merged by
FreeBSD's large-receive-offload rule before classification. Every TCP
decision stays in Erlang
([design-network-stack.md](design-network-stack.md#the-fast-path)).

The stack is written by translating the logic, not the structure, of
FreeBSD's `netinet` and `netinet6` into Erlang, from FreeBSD's default
TCP stack with CUBIC: their protocol state machines, timers and
handling of the cases that interoperability taught them become
processes and binary matches, and nothing of their C layout is kept. The
pin is commit `975e3605ebb1` of FreeBSD 16.0-CURRENT, the kernel of the
FreeBSD test host; the translation was read from FreeBSD 15.1
(`release/15.1.0-p6`), and of FreeBSD's changes since, those the wire or
an interoperating peer can see and the fixes of real bugs are ported,
not the rest. Loss detection and congestion
control are behaviours from the start, mirroring FreeBSD's function block
and `struct cc_algo`, so RACK-TLP and BBR, which are deferred, come
later as modules behind them.
[design-network-stack.md](design-network-stack.md) is the stack's design:
the translation's rules, the processes that own its state, the packet
path, grants and sockets, and its verification. The stack is an ordinary
OTP application, `erx_net`, that also runs on stock OTP outside erXos:
the driver's transport, the clock with the entropy source, the per-byte
primitives and the runtime's calls for grants are seams, each with an
erXos implementation and a portable one, so the stack is tested on a
development host against real peers and can be used, and released, on
its own.

Whether TCP's fast path, the in-order data and acknowledgement path of an
established connection, also needs native code is decided by measurement
on erXos's kernel. A prototype of the packet path, UDP echo and a TCP
bulk transfer, is first measured on QEMU on Fiasco, as a baseline
that decides nothing, since every interrupt and doorbell there passes the
root's one service thread; the same measurements on erXos's kernel
decide, and the Raspberry Pi 4 confirms or reopens the decision (gates
GN-QEMU, GK3 and GN-board of [plan.md](plan.md#decision-gates), with the
frame rates and floods each offers). If the stack cannot keep up, only
the pure function of TCP's core that the measurement names moves to
native code, behind the same signature and process interface, as a
measured exception, and everything else stays Erlang.

The network domain runs on its own grant. Traffic that names no
admitted client spends a token bucket of its interface; every hand-over
of packets between the stack's processes is against a credit its
receiver published, so every queue is bounded and excess is dropped
where it arrives while control progress is reserved; and work for a
client is bounded by that client's grant, so a small packet or request
never stands in for a bound on the computation it causes.

FreeBSD 16 is the stack's reference oracle: the FreeBSD test host,
16.0-CURRENT, and its vnet jails. No stopgap stack precedes erXos's: the
network service runs it from its first release. FreeBSD's TCP test
suite, packetdrill scripts of timed packets in and expected packets out
(N. Cardwell et al., "packetdrill: Scriptable Network Stack Testing,
from Sockets to Packets", USENIX ATC 2013), runs on the test host and
against erXos's stack, and every script's verdict must agree with the
newest record of the host's, which names the kernel it ran on, since
the host tracks -CURRENT; the records live in the history repository.
Traffic tests run against the host's jails and against Linux's stack,
which is an interoperability peer, not the reference. A domain's use of the network is one grant, a facet process
in the network domain that holds the domain's limits on sockets, buffers
and ports and an account of the reductions its sockets spend, on
requests and on packets alike, against the domain's share, so no domain
can exhaust the stack's pools or time for others; the inspector shows
each grant's use. TCP distribution to other machines, TLS and SSH build
on the network service. Every domain is an Erlang node already, and a
domain that other machines may reach carries its own distribution
connections over the network service under the same node name
([Decisions](#decisions)), its pids encoded as stock encodes them, with
its domain id as the creation. The network domain's port mapper answers
epmd's protocol for the names that exposed domains register through
their grants, each its own name only. A release build carries
distribution to other machines only over OTP's TLS carrier. An exposed
domain keeps its node name on the network; the network carrier refuses a
remote node that claims a name at the machine's host name, and pids of
other machines never cross a lane. A file
server that other machines mount speaks 9P2000.L's messages through the
same codec as the host link
([design-files.md](design-files.md#the-file-protocol)). A program's
socket is an open-file description of its session, as a file's is, so a
spawn, a fork, `SCM_RIGHTS` and an `exec` within the session share or
keep it as they do any open; only moving a socket to another domain is
not offered, since a socket acts for its grant's domain alone
([design-programs.md](design-programs.md#descriptors-and-files)).

## Formats

| Format | Version | Owner | Validated by |
| --- | --- | --- | --- |
| The kernel interface and fixed layouts (`abi/erx_abi.txt`): calls, rights, status codes, limits, shared areas, boot information, the machine page, rings, reader pages, records, frames, crash headers, the medium layout | `ERX_ABI_VERSION` | [design-kernel.md](design-kernel.md#the-abi-file) | generated decoders and validators |
| Frame profile: OTP 29.1.2 distribution control messages and an external-term-format subset | part of the ABI's version | [design-domains.md](design-domains.md#frames) | the funnel |
| Boot image (`ERXPACK`) | 2, which names BLAKE3 as its hash | [design-kernel.md](design-kernel.md#the-boot-image) | the boot validator for the index, and the file check at each file's first slice |
| Boot locator, in the first stage of the bootable file | 1 | [design-kernel.md](design-kernel.md#the-bootable-file) | `erx_boot_locate` |
| Image manifests | 1 | [design-kernel.md](design-kernel.md#image-manifests) | the kernel's image checks and the domain library's plan |
| The system manifest: every configured domain with its principal, image, budget, grant, devices, facets and introductions | 1 | [design-system.md](design-system.md#the-manifest) | the manifest check at build time, for the properties the security argument rests on; then, in the system domain, the manifest reader, bounded and fuzzed |
| Read-only images: the EROFS on-disk format, under a dm-verity hash tree | the format's feature bits; dm-verity's format version 1 | [design-storage.md](design-storage.md#data-model) | the EROFS reader in the consuming domain's runtime, on blocks that passed the hash tree |
| Read-write storage: the F2FS on-disk format, and littlefs's, its stopgap | the superblock's feature bits | [design-f2fs.md](design-f2fs.md#scope-features-and-forms) | erXos's F2FS, which mounts read-write only the features it maintains, read-only those it can read, and refuses the rest, the encryption, compression and atomic-write feature flags among them |
| A drive's tables and volumes: an MBR, a GPT or none; FAT16 and FAT32 with long names and uncompressed EROFS, and in development builds and test images littlefs of erXos's geometry | FAT32's file-system version, 0.0; EROFS's feature bits; littlefs's own | [design-drives.md](design-drives.md#reading-a-medium) | the media domain's table reader and probe, which refuse a table whole or name a format they do not serve, FAT12 among them, and each format's mount, the FAT server refusing another version |
| Slot images and update manifests | 1 | [design-storage.md](design-storage.md#system-updates) | the update service, after the manifest's signature, which a development build checks against the development key it embeds |
| The local start table, `/etc/start.conf`, in rc.conf(5)'s assignment syntax: the literal subset of [The file's syntax](design-apps.md#the-start-table), nothing executed | 1 | [design-apps.md](design-apps.md#the-start-table) | `erx_start_conf:read/1` and the settings judgement, `erx_start_settings:judge/2`, bounded and fuzzed, which skip and report each line that is a problem, at every read |
| App packages: a header with the packed declaration, the image's root hash, signer and signature, then an EROFS image and its dm-verity tree (`abi/formats/package.txt`) | 1, and the `ERX_ABI_VERSION` and architecture the package was built for | [design-packaging.md](design-packaging.md#the-package) | in the system domain, `erx_pkg_header:check_file/2`, the generated reader, bounded and fuzzed, then the signature or the manifest's hash of the header; the image by the reading session's own EROFS reader, the app's or a person's that mounted it, on blocks that passed the hash tree |
| App declarations, `app.txt`, in the manifest source's syntax | 1 | [design-packaging.md](design-packaging.md#the-declaration) | the packer's parser on the host, bounded and fuzzed; the machine reads only the packed form |
| NTP packets: SNTPv4 requests and replies | version 4 | [design-time.md](design-time.md#checks-on-a-reply) | `erx_ntp_wire` in the ntpd session, and in root's session while root runs `ntpctl step`, bounded and fuzzed, then `erx_ntp_sample`'s checks on a reply |
| The vault's files: a principal's keys and credential slots, and the machine's file | 1 | [design-system.md](design-system.md#the-vault) | the vault's file decoder, bounded and fuzzed, then the slots' authenticated encryption |
| TPM 2.0 responses | the TPM 2.0 library specification's | [design-system.md](design-system.md#the-vault) | the vault's TPM client's response decoder, bounded and fuzzed, then the session's HMAC |
| The boot-selection record: the firmware's `autoboot.txt` on the Raspberry Pi, the same file read by the harness on QEMU; with the firmware's one-shot trial request, two states, `normal(C)` and `trial(S)` | the firmware's | [design-storage.md](design-storage.md#system-updates) | the slot writer, which rewrites it only from one of its two encodings, one per committed slot |
| Host-link frames and sessions, with stream 4 carrying files, one 9P2000.L message per frame within an `msize` of 4,096 | 2 | [design-live.md](design-live.md#host-link-frames) | the deframer and the host grammar; another version is refused |
| The file protocol: 9P2000.L's operations, as terms in frames on connections inside the machine, and as 9P2000.L bytes at the edges, the host link's files stream, QEMU's virtio-9p and the network | 9P2000.L, agreed by its `version` operation; the frame profile is part of the ABI's version | [design-files.md](design-files.md#the-file-protocol) | inside the machine, the funnel's grammar, then `erx_fs` and `liberx`'s client, both generated from the profile; at the edges, the generated codec `erx_9p`, bounded by `msize` and fuzzed |
| A program's startup message and the channel protocol between a program and its handler | 1 | [design-programs.md](design-programs.md#the-channel) | `liberx`'s channel decoder, before `main` and at every reply; the handler's decoder, bounded, in the session |
| Code blobs and manifests | manifests 1; a blob is its bytes, named by their SHA-256 | [design-live.md](design-live.md#the-code-store) | the code server's hash check; manifests by the code service's request reader |
| `/proc` and `/dev` files | the inspection schema's | [design-live.md](design-live.md#the-proc-tree) | their servers, which encode entry names injectively and frame values with `\t`, `\n` and `\\` |
| `grep`'s patterns: POSIX basic and extended regular expressions | POSIX.1-2024's | [design-shell.md](design-shell.md#text-commands) | `erx_grep_re`, bounded and fuzzed |
| System identifiers | the rule `[a-z0-9][a-z0-9_-]*`, 1 to 63 bytes | [design-system.md](design-system.md#identifiers) | `erx_ident:new/1` |
| Inspection records | schema 1 | [design-live.md](design-live.md#inspection-records) | the host tool's decoder |
| Escape rules (`abi/terminal.txt`) | generated per build, checked by build identifier | [design-live.md](design-live.md#escape-rules) | generated escapers |
| Register descriptions (`hw/svd/**/*.svd`, CMSIS-SVD) | the SVD schema's | [One source](#one-source-for-the-abi-and-the-hardware) | the generator and its determinism test |
| System-register specifications (`hw/sysreg/<arch>.json`) | the release of the architecture's specification each was extracted from | [One source](#one-source-for-the-abi-and-the-hardware) | its reader; `tools/erx sysreg refresh --verify` compares it with the release on demand |

## Repository layout

```text
Makefile          top-level build; the only entry point for everything below
deps.lock         third-party sources fetched unchanged: URL, version, SHA-256
abi/              erx_abi.txt with inspection.txt and services/ fragments,
                  arch/ (a file per architecture), terminal.txt:
                  sources of generated code and reference tables
hw/               svd/ and sysreg/: sources of generated accessors;
                  arch_terms/: each architecture's terms, for the check
kernel/           erXos's kernel, C17 and assembly; files derived
                  from Fiasco carry its notice (kernel/NOTICE-fiasco)
  core/           the functional core shared with Fiasco: scheduler,
                  park and defer machines, budgets, mapping plans, decoders,
                  the boot-image validator, the entropy generator
  crypto/         imported C primitives as erXos's code, a directory per
                  upstream directory, each with an ORIGIN.md: FreeBSD's
                  SHA-256 (sha2/) and ChaCha20 (chacha20/), and BLAKE3's
                  portable C (blake3/); the cores' archive builds them
  arch/<arch>/    the architecture layer, a directory per architecture
  platform/       the platform layer: device-tree discovery and the
                  devices the kernel drives
fiasco/           Fiasco: Fiasco, bootstrap, sigma0, l4sys, libfdt and
                  mk as erXos's code, each with an ORIGIN.md
liberx/           the library all user-mode code links: generated calls and
                  their erx, fiasco and hosted backends; erx_etf,
                  the funnel, the lane and channel code, the DMA envelope
                  and the device NIF's native part; the system layer: the
                  root-task entry and the domain library; the POSIX-lite
                  personality; erx_exec, the loader of executables from
                  files
otp/              Erlang/OTP 29.1.2 as erXos's code (otp/ORIGIN.md)
  erts/emulator/sys/erxos/
                  the adapter, the connection carrier and the export table, the
                  program port driver, prim_file's
                  platform layer, the per-byte primitives, the block and
                  packet clients, the hash-checking reader, float
                  conversion, crash output
  erts/preloaded/src/
                  erx_erofs, the EROFS reader, beside prim_file
musl/             musl 1.2.6 as erXos's code (musl/ORIGIN.md)
erlang/apps/      erx and the system services, the drivers (one
                  application per device class, over erx_device; a native
                  shim the driver table lists lives in its application's
                  c_src/ and runs as a sub-space port), the storage
                  services (erXos's F2FS, the slot writer), the media
                  domain's erx_media with the FAT server
                  and the network stack (erx_net, with NOTICE-freebsd)
toybox/           toybox 0.8.15 and wak as erXos's code (toybox/ORIGIN.md)
storage/          littlefs's NIF glue, C17, a stopgap
tools/            Ruby: erx (build, pack, qemu, bench, console, inspect,
                  watch), generators, the stack, chokepoint and manifest
                  checks, test runners
specs/tla/        TLA+/PlusCal models, configurations, expectations and
                  invariant-to-implementation mappings
test/             conformance, transcript, oracle, hosted and fuzz tests
bench/            benchmark workloads; their results live in the history
                  repository (design-bench.md)
docs/             design, plan, research records, style
sdk/              the SDK's own sources: erx_ui_host and sdk.mk; tools/erx
                  sdk export writes the SDK from a built tree
examples/         example apps that no list of the build names, each built
                  only through the SDK, but for the Doom demo, which the
                  published build compiles (DoomProgram), a git submodule,
                  only its gitlink in the tree, with an ORIGIN.md beside it
```

## Build and toolchain

The development host is macOS on Apple Silicon. Tools, installed through
Homebrew or built from pinned sources: LLVM's clang and `lld` (the latter
a separate formula) for erXos's own code, the runtimes, and Fiasco and L4Re
(with LLVM's binary tools beside clang); GNU make 4.4.1 and
Perl for Fiasco, as L4Re's macOS guide prescribes
([research](research-hierarchical-scheduling.md#fiasco-under-hvf)); Ruby;
QEMU 11.1; `dtc`; CBMC, at the version `test/cbmc/roster.json` pins, for `make check-cbmc`; `b3sum`, the oracle the imported BLAKE3 is compared with;
`blew`, a macOS Bluetooth LE command-line tool, which `tools/ble_board_check.rb` drives for the scripted part of the Pi 4 Bluetooth checklist;
GNU coreutils for `gtimeout`, the harness's deadlines;
git, which lists the project's files for the source check;
and native host OTP, stock OTP 29.1.2 built from the pinned tarball with its
own `configure`, which provides `erlc` for every Erlang file erXos ships
and the native performance baseline
([research](research-erts-internals.md#sizes-and-toolchain-probe)).
Homebrew's OTP is a different release and cannot cross-build 29.1.2
([research](research-erts-host.md#build-configuration)).

`make fetch` is the only step that touches the network: it reads
`deps.lock`, downloads each source, verifies its SHA-256 and unpacks it
into its own directory under `build/third_party/`, unless that directory
already holds the pin's tree, unchanged by the digest recorded when the same
extraction code unpacked it; a copied or moved build directory keeps its
trees. It also pulls the oracle's pinned OCI toolchain images by manifest
digest. Every other target runs offline. The top-level `Makefile` builds the kernel or Fiasco
(through Fiasco's `mk`, behind `tools/erx build fiasco`), `liberx`, the
runtime image (through OTP's machinery, behind `tools/erx build
runtime`), toybox, any native shim the driver table lists, and the boot image
(`tools/erx pack`, deterministic, after the manifest check has passed on
the system manifest it packs); `make check-reproducible` rebuilds the
boot image and the EROFS images and compares bytes, and checks that no
image holds the build root's path. Every long-running command the tools
start (builds, QEMU guests, suites, benchmarks) runs with standard input
closed, output in a log and a hard deadline, as
`gtimeout -k 10 SECS cmd ...`, and every QEMU guest with `-no-reboot`.

## Testing and the oracle

[Protocol verification](design-verification.md) defines the TLA+/TLC suite,
its independent models, invariant-to-code mapping and host exploration of
the actual pure cores. `make check-tla` is a separate required gate when
modeled mechanisms change; release validation runs the whole suite uncached.
The roadmap schedules the models and the CBMC and awklog evaluations.

**The full oracle is stock OTP 29.1.2 in an offline Linux container on the
development host.** On macOS, a local Docker-compatible provider such as
OrbStack supplies the Linux VM; on Linux, the engine may run natively. The
[oracle context](design-host-oracle.md) owns the container's process and
network namespaces, deadlines and complete cleanup. Native macOS OTP remains
the bootstrap/compiler input and a separate native performance baseline.
Every report names its actual execution environment.

The same `.beam` files run in the oracle and on erXos; OTP's own test suites
for the applications erXos keeps run on both, and a Ruby tool compares the
results case by case. Every difference is a bug in erXos, a documented difference
with a test, or an upstream bug recorded as such. Checked-in rules map each
class of case that differs to its explanation, such as the printing of
pids as `<D.N.S>`, or to the reason it cannot run yet, which the run must
show. The comparison fails on a difference that no rule explains, and on a
rule that matches no case.
musl's `libc-test` runs in a test domain under the same rule, and so
do the Open POSIX Test Suite for the POSIX-lite personality, toybox's own
tests for its applets, and plan9port's rc for the command shell, whose
scripts run under both.

The layers of testing:

| Layer | What | Where |
| --- | --- | --- |
| Unit and property tests of the functional cores (the kernel's core, the scheduler's machines, the funnel, the lane protocol, the channel protocol, the domain library's plans, the adapter's decisions, the device NIF's address checks, `erx_etf`, the boot-image validator, the update state machine) | built for the host, under ASan, UBSan and, for concurrent code, TSan; protocol state machines explored exhaustively | host |
| Protocol models | independent TLA+/TLC models with finite scopes, good and deliberately broken configurations, reachability witnesses and implementation mappings | host, `make check-tla` |
| Build checks | the chokepoint checks, the stack proof and cycle checks, the generated tree's determinism test and ASCII refusal; generator rejection tests and seeded violations; generated parser scaffolding complemented by independent fixtures and oracles | every build |
| Hosted mode | runtimes, the domain library and the system services on `liberx`'s hosted backend, with OTP's suites, under the sanitizers and `lldb` | host |
| Conformance | every kernel call's contract, run identically on both kernels for every call the Fiasco backend carries | QEMU, HVF |
| Transcript tests | boot, shell sessions, domain lifecycle, connections taken down, driver restarts, a watchdog reset, scripted through the console and the host link | QEMU, HVF, with one boot smoke test under TCG; a test that passes under only one accelerator is a bug until explained |
| The oracle | OTP's suites in a test domain against stock OTP built on the development host, `libc-test` in a test domain, and erXos's F2FS's deep runs against Linux's F2FS and `fsck.f2fs` in their guests (`make check-oracle`); stock OTP's own suites alone in the isolated Linux oracle (`make check-oracle-host`) | QEMU on the development host, and a Linux container there |
| Deterministic mode | `erx.det=1`: one CPU, TCG with instruction counting, the interpreter; byte-identical transcripts | QEMU, TCG |
| Differential tests | the funnel against `binary_to_term/1`; float conversion against the host; cross-domain behaviour against two connected stock nodes; erXos's kernel against Fiasco; each recombined ERTS part against its predecessor; erXos's F2FS against Linux's in a QEMU guest and against littlefs; the EROFS reader, on images fsimg writes, and the FAT server, on images fsimg creates and by fsimg's verify of the images it writes; the network stack against FreeBSD's on the FreeBSD test host and against Linux's, by interoperation and scripted packet tests; each per-byte primitive against its reference on the host; the command shell against plan9port's rc, and its commands named like FreeBSD utilities against FreeBSD 15.1's in the oracle guest | host and QEMU |
| Benchmarks | the operations of [design-bench.md](design-bench.md) with their distributions, compared within one environment; a lost wake fails, and on the Raspberry Pi 4 so do console and SD receipts past their limits | QEMU under HVF and in deterministic mode; the Raspberry Pi 4 beside L4Re and Linux; a program's POSIX calls beside Linux and Genode ([design-bench.md](design-bench.md#what-a-program-sees-posix-and-erl)) |
| Fuzzing | every parser of untrusted input, built for the host from the same sources, each target landing with its parser; each design document's verification section names its own targets, and `make check-fuzz` runs them all for their configured budgets | host |
| Hostile programs | domains and programs that attack the kernel's calls, their lanes and channels, forge pids and exits, fill lanes and never drain them, send malformed frames, and ignore kills | QEMU |

## Performance

Every number below is an estimate until measured on erXos, unless marked.
The measured figures come from two research records, both taken on
2026-10-29 on an Apple M4 Max under macOS 27.0.1:
[research-baselines.md](research-baselines.md) for the traps (QEMU 11.1.2,
machine type `virt-11.1`, HVF, the probe assembled by clang 23.1.4) and
for ERTS (Homebrew's OTP 28.4.2 in its JIT flavour, on the host itself),
and
[research-hierarchical-scheduling.md](research-hierarchical-scheduling.md#fiasco-under-hvf)
for Fiasco (the same QEMU under HVF, with `-cpu host` and four CPUs, the
kernel built by `aarch64-elf-gcc` 16.2.0). The records give no compiler
flags for these three: the probe is hand-written assembly, Homebrew built
its OTP with flags of its own, and Fiasco was built with its default
configuration, so a re-measurement records them. The host was shared and
heavily loaded during both, with load averages of 38 to 81 during the ERTS
runs, so the ERTS figures are noisy: two runs of one ping-pong gave 410 ns
and 1,734 ns. The budgets compare with stock OTP 29.1.2 in the same
flavour on the same Mac, which gate G3 measures.

| Measure | Budget | Basis |
| --- | --- | --- |
| Null kernel call, HVF | 40 ns | the trap and a capability lookup, estimated from these measurements: 22 ns for a minimal trap from user mode and return, 31 ns with an address-space switch ([research](research-baselines.md#exception-and-address-space-switch-costs)); Fiasco's null call 29 ns ([research](research-hierarchical-scheduling.md#fiasco-under-hvf)) |
| IPC call round trip through a gate on one CPU, HVF | 300 ns | Fiasco's IPC measured 51 ns one way within a space and 89 ns across spaces, inferred from an emulated counter ([research](research-hierarchical-scheduling.md#fiasco-under-hvf)), plus decoding (estimate) |
| Process switch, spawn and local message inside an ordinary domain, HVF | within 1.2x stock OTP 29.1.2 in the same flavour on the same Mac | no extra kernel entry on its local scheduling path (estimate); the exploratory OTP 28.4.2 baseline is not the acceptance baseline |
| Cross-domain round trip, small message, HVF | 3 us with busy executors, 10 us with parked ones | per direction one encode into the lane's ring, one copy out of it by the funnel, one funnel pass, and a doorbell trigger only when the receiver is parked: at most two kernel calls, two funnel passes and four copies for the round trip, plus wakes (estimate); distribution over TCP loopback measured 57 us on the host ([design-domains.md](design-domains.md#performance)) |
| A program's start, from the session's `spawn` to its `main` | the programs document's budget | two space creations, a budget carve, a group, the pipe ends, a channel and one thread, each a kernel call charged to the session, plus the image's mapping ([design-programs.md](design-programs.md#a-program-is-a-port)) |
| Boot to the system shell, HVF | 1 s | OTP's embedded boot measured 0.13 s on the host in the JIT flavour, which translates every module it loads, plus the kernel and the root-task entry; the system domain interprets, so it translates nothing and runs slower (estimate) |
| BeamAsm over the interpreter | 1x to 4x faster | cited: "anything from no difference to up to four times as fast" (OTP's `BeamAsm.md`) |
| Translating a BeamAsm domain's boot modules | 0.8 to 2.4 ms per module | measured: 178 modules in 146 to 427 ms under OTP 28.4.2's JIT on the host ([research](research-baselines.md#beamasm-code-size-and-load-time)) |

**Experiments that decide.** The scheduler's experiments E-S1 to E-S10
([design-scheduler.md](design-scheduler.md#performance)) compare the
configurations from plain threads to full cooperation, and the dispatch
models (plain one-to-one threads, runtime grants, and a kernel thread per
process) on the same kernel; the domain experiments E-D1 to E-D4
([design-domains.md](design-domains.md#performance)) measure cross-domain
messaging, the number of connections a machine carries, deaths and kills, and
senders' traffic while some of their receivers stop draining.
[plan.md](plan.md) gates work
on them. Every
measurement records host, accelerator, QEMU version, compiler, flags,
workload and baseline, and TCG numbers are never compared with HVF or
native numbers. [design-bench.md](design-bench.md) is how: one record per
run in the history repository, one clock per interval, comparisons only
within one environment, and three limits that fail a gate.

Acceptance measurements use the same OTP version, runtime flavour, workload
and recorded machine load. They separate a domain's local work from
requests to shared services, report kernel entries per request, and
include p50, p99 and p99.9 latency for a multi-service request under
overload, with a saturated service's clients measured together, since
they slow together. TCP distribution is one comparison, not evidence
that a transport change alone caused a speedup. A result without matched
conditions remains exploratory evidence.

## Failure handling

| Failure | Blast radius | What the user sees |
| --- | --- | --- |
| An Erlang process crashes | the process; links and monitors deliver its exit | OTP's usual supervision |
| A runtime faults, halts, crashes or exhausts its memory | its domain | links and monitors fire with `{domain_down, D, Info}`; the crash dump in the inspector |
| A group exhausts its quota | its threads wait for the next period | slower progress; throttling in the inspector |
| A driver process crashes | that driver; its supervisor resets the device and restarts it | a restart in the log; clients see the driver's process exit and reconnect |
| A driver domain faults, a native shim in a sub-space included | the domain's drivers and their clients | as any domain: `{domain_down, D, Info}` to its links and monitors; the system domain's supervision restarts the domain |
| A domain exceeds a limit | the failing operation, or throttling for CPU | Erlang errors in the domain; counters in the inspector |
| A malformed kernel call | the call fails with a status | a trace event |
| A malformed frame arrives on a lane | that connection: the receiver stops reading the lane and tells the system domain, which takes the connection down for both | `noconnection` on everything the peer had across that connection, as at a net split; a trace event |
| A sender fills its lane | the sending processes, which wait in their own runtime | a `gen_server:call` to a stalled peer blocks the caller and nobody else; the inspector shows the lane full |
| A program faults or exits | the program and every sub-space it started | its owner process gets `{exit_status, N}`; the handler closes the program's descriptors |
| The system domain's runtime faults or halts outside an ordered shutdown, or misses the watchdog | the machine: every domain's space is its child | the machine's end by `erx.panic`, a reset in release builds, after a crash record written into a region that survives a warm reset where the platform has one, else to the console and the log; the inspector shows the record at the next boot only to the system shell; past three such ends in a row, the next boot is the rescue configuration |
| A kernel invariant fails, or an asynchronous error is uncontainable | the machine | a panic report with registers |
| A storage domain or the slot writer faults | its partition's clients, whose requests fail until it restarts | errors from the file interface; its supervisor restarts it, and the file system recovers to its last checkpoint at mount, read-only on a trial boot |
| The data partition does not mount | the files on it | a report; the partition is served read-only or not at all, and never formatted except at an operator's request or by the update that replaces littlefs |
| The vault's partition does not mount, or its sealing backend does not answer | logins and enrolment; sessions already open keep their keys | every login and enrolment answered `unavailable`, never taken for a principal that has not enrolled; the console says why ([design-system.md](design-system.md#the-vault)) |
| A slot write or its read-back fails, or the spare is left half-written | the update | the update fails with a report of the mismatch; the committed slot is untouched, and a spare that does not verify against its update manifest at boot is never booted |
| A trial fails, by deadline, panic, hang, power cut or an end of the system domain | the trial | the machine boots the committed slot, with the data partition as that system left it; the record still naming that slot after a trial is the failure, and the update is not retried automatically |
| A commit's outcome is unknown, its write interrupted | the update | the slot writer reads the record back, and the record decides which slot is committed |
| The firmware drops the trial request (a Pi 4 of revision 1.0 or 1.1 with a write-protected EEPROM) | the update | the machine boots the committed slot, and the record still names it, which the update service reports as a failed trial |

## Compatibility

OTP applications run unmodified within a domain. The differences from a
UNIX host
([design-runtime.md](design-runtime.md#erlang-visible-behaviour)) and the
differences between domains from two connected nodes
([design-domains.md](design-domains.md#compatibility-and-migration)) are
closed lists, each entry with a test. Every format carries a version, so a
mismatch fails loudly; the kernel, `liberx` and the runtimes come from one
tree and refuse an image built for another ABI version.

No erXos format, protocol, interface or stored state owes compatibility to
its own earlier forms until a release promises it. A change replaces the
old form outright, with no conversion, migration, shim or reader for old
versions: an installation re-creates what an earlier build wrote, and
state that does not parse is refused with a diagnostic, never misread. So
the data partition and the vault's partition, which littlefs serves until
erXos's F2FS, are created afresh by the installation that brings erXos's
F2FS, and an update whose release reads another storage format than the
running system's is refused, since its trial could not read the partitions
([design-storage.md](design-storage.md#system-updates)). Two rules that
look alike are not compatibility and stay: the update path refuses a
manifest below the running system's security version, a rule against
rollback, and erXos keeps behaving like stock OTP, musl and POSIX wherever
its tests require.

## Portability

QEMU `virt` is the first platform, then the Raspberry Pi 4 Model B, then
the Raspberry Pi 5, all AArch64. Boards sit behind the kernel's platform
layer (device-tree discovery, the interrupt controller and MSI frame, the
timer, the UARTs, the real-time clock, the IOMMU, the boot random
generator, the watchdog, the firmware's mailbox, and the early console),
so a port to a board touches that layer only; a board's other devices have
Erlang drivers above it ([Drivers and DMA](#drivers-and-dma)). Processors
sit behind the architecture layer, which implements the kernel's port
contract: its modes, entries and system-call trap, translation, the
timer, and the firmware calls that start CPUs and end the machine ([design-kernel.md](design-kernel.md#port-contract)). A
port to an architecture touches that layer, `liberx`'s trap stubs and the
architecture's files beside the ABI and the register sources only.
Architecture-specific code outside the kernel is ERTS's own code for each
architecture, BeamAsm's back end and musl's architecture layer. Each
architecture's terms and facts live in its binding,
[design-arch-aarch64.md](design-arch-aarch64.md) for AArch64, and the
platforms' in [design-platforms.md](design-platforms.md); generic designs,
interfaces and names say kernel mode and user mode, and
`make check-arch-terms` keeps the rest out of generic code and documents
([Chokepoint checks](#chokepoint-checks)). The development host is macOS
on Apple Silicon, then Linux on AArch64 and x86-64, for the host tools,
hosted mode and the oracle.

What each board adds, from its interrupt controller and firmware to its
early console, its system manifest, PCIe, DMA, entropy, watchdog and
trial request, is in
[design-platforms.md](design-platforms.md).

## Dependencies

FreeBSD is read at one reference release, 15.1: a document or source
file that cites FreeBSD's source cites the tag `release/15.1.0` or its
patch release `release/15.1.0-p6` (`95719d8a`). The network stack is
pinned apart, at the FreeBSD 16.0-CURRENT commit its design names.
Research records keep the release they were checked against.

A row's status is one of four. `permanent`: kept for good. `stopgap`:
used to reach a working system and replaced later; a release ships only
the stopgaps its milestone names, each under the release contract its
design states (littlefs and LVGL for 0.2), and no other. `release`: in a
release's trusted base and replaced later, with its replacement planned
in [plan.md](plan.md) and what it lacks against that replacement
published with the release. `example`: a demo shipped in the published
images of a preview release only, never part of the system, its source
offered with the image; Doom for 0.1 is the one, and the image build
accepts the `example` status for its archive alone, under GPL-2.0-or-later
(`LicenseCheck::EXAMPLE`). Tools and test data never enter a shipped image; test images carry test tools under an allowlist of their own ([Licenses and notices](#licenses-and-notices)).

The table gives each dependency's purpose, license and status. Code
erXos changes enters the tree as erXos's code with an `ORIGIN.md` beside
it, which records its version, source and the SHA-256 of what was
imported; everything used unchanged is fetched at a pinned version and
SHA-256 (in `deps.lock`, `web/pnpm-lock.yaml` or the owning design) and
built out of tree, its own build scripts not run unless the row says so.

| Component | Purpose | License | Status | Origin |
| --- | --- | --- | --- | --- |
| Erlang/OTP 29.1.2: ERTS and the shipped applications | the runtime and the system's Erlang code | Apache-2.0; `public_key`'s PKCS #3 and #5 ASN.1 specifications under their own permissive notices, carried in every image with those modules | permanent | [otp/ORIGIN.md](../otp/ORIGIN.md) |
| OTP's Common Test controller, a reporting copy | exact case and job records for the host oracle ([design-build.md](design-build.md#oracle-and-protocol-models)) | Apache-2.0 | permanent, development only | [test/oracle/common_test/ORIGIN.md](../test/oracle/common_test/ORIGIN.md) |
| Third-party code inside OTP: asmjit, PCRE2, zlib, zstd, Ryu | the JIT's assembler (BeamAsm image only), `re`, `zlib`, `zstd`, float printing | asmjit and zlib Zlib; PCRE2 BSD-3-Clause WITH PCRE2-exception; zstd BSD-3-Clause; Ryu Apache-2.0 | permanent; asmjit never in the system domain's image | part of `otp/` |
| musl | the C library of every runtime and native program | MIT, with the parts listed in [research](research-c-library.md#musl-126) | permanent | [musl/ORIGIN.md](../musl/ORIGIN.md) |
| Fiasco, with `bootstrap`, `sigma0`, `l4sys` and `mk` | the kernel of Phase 1 and of the first release, behind erXos's interface ([design-fiasco.md](design-fiasco.md)) | MIT, except the GPL-2.0 `jdb_object.cpp`, which only a kernel with the debugger compiles; the tree's `kobject_rpc.h` is erXos's MIT clean-room replacement of Fiasco's GPL-2.0 original ([design-fiasco.md](design-fiasco.md#the-releases-fiasco-build)); the configuration tool of the kernel and `mk` (`tool/kconfig`, GPL-2.0) runs on the host while a build is configured and is compiled into no executable a boot image carries; Fiasco's other GPL and LGPL parts, and the parts no erXos build uses (Fiasco's own tests, bootstrap's MIPS and R-Car R52 start code, mk's test plug-ins, libstdc++), are excluded at import, each an exclusion row of its tree's `ORIGIN.md`; every file kept is recorded in its tree's inventory under its own notice's license, or as `LicenseRef-unrecognized-notice` where the inventory does not recognise the notice, which LicenseCheck refuses in any closure; the release audit reads every executable a boot image carries (the kernel, `bootstrap`, `sigma0` and each board's own `bootstrap`) | **release**, replaced by erXos's kernel in Phase 2 if gate GF of [plan.md](plan.md#track-f-fiasco-improved-to-the-decision) chooses it; built with LLVM like everything else, its freestanding headers Apache-2.0 WITH LLVM-exception; 0.1's images carry a development kernel, with the debugger and `jdb_object.cpp`, by decision, under CLAUDE.md's exception for the website's images with their source offered, and 0.2's release the release kernel's build without them ([site/README.md](../site/README.md), [design-kernel.md](design-kernel.md)) | [kernel](../fiasco/kernel/ORIGIN.md), [bootstrap](../fiasco/bootstrap/ORIGIN.md), [l4re-core](../fiasco/l4re-core/ORIGIN.md), [mk](../fiasco/mk/ORIGIN.md) |
| Code translated from Fiasco into erXos's kernel | the kernel's design and know-how | MIT, notice kept per file and in `kernel/NOTICE-fiasco`; only from files whose effective license is permissive ([Licenses and notices](#licenses-and-notices)) | permanent | written in `kernel/` |
| libfdt | device-tree parsing in the kernel, Fiasco and the root task | BSD-2-Clause (dual GPL-2.0-or-later) | permanent | [fiasco/libfdt/ORIGIN.md](../fiasco/libfdt/ORIGIN.md) |
| `drivers-frst`, its PL011 UART subset | `bootstrap`'s console during Fiasco's boot | MIT | **release**, replaced with Fiasco | [fiasco/drivers-frst/ORIGIN.md](../fiasco/drivers-frst/ORIGIN.md) |
| Plan 9's `libmemdraw`, from 9front | the per-byte pixel primitives of `erx_memdraw` ([design-display.md](design-display.md#dependencies)) | MIT | permanent | [display/libmemdraw/ORIGIN.md](../display/libmemdraw/ORIGIN.md) |
| LVGL 9 | the native widget renderer, a program of the application's session | MIT; the fonts in its archive are Inter's, OFL-1.1, admitted as font data only | stopgap, shipped in 0.2 under its [release contract](design-display.md#lvgls-release-contract), retired by the Erlang renderer at gate GD ([plan.md](plan.md#decision-gates)) | submodule `display/lvgl/lvgl` of erXos's fork, [ORIGIN.md](../display/lvgl/ORIGIN.md) |
| React and React DOM, with their type definitions | the web client's rendering ([design-web.md](design-web.md#dependencies)) | MIT | permanent, in the web domain's release | `web/pnpm-lock.yaml`, install scripts off |
| TypeScript 7, esbuild | the web client's type check and bundling; esbuild also bundles the book site's diagram library ([design-book-site.md](design-book-site.md#the-import)) | Apache-2.0; MIT | permanent host tools | `web/pnpm-lock.yaml` and `tools/book/pnpm-lock.yaml`; run as subprocesses |
| Playwright with its Chrome Headless Shell; `@types/node` | the web client's browser tests and their type check | Apache-2.0, Chromium BSD-3-Clause; MIT | test tools | `web/pnpm-lock.yaml`; the Chromium in `deps.lock` |
| cowboy, cowlib and ranch | the web domain's HTTP, WebSocket and TLS acceptance ([design-web.md](design-web.md#the-network-front-end)) | ISC | permanent | fetched and built against erXos's OTP, or imported if changed |
| plan9port's `fixed` fonts | the terminal's and the Erlang renderer's glyphs | public domain (X.Org's `misc-fixed`) | permanent | [display/font/fixed/ORIGIN.md](../display/font/fixed/ORIGIN.md) |
| Inter | the desktop theme's type ([design-desktop-programs.md](design-desktop-programs.md#type)) | OFL-1.1, font data only; the glyph files generated from it carry OFL-1.1, their generators BSD-2-Clause | permanent | [display/fonts/inter/ORIGIN.md](../display/fonts/inter/ORIGIN.md) |
| FreeType | the theme's glyph step, in the host program `erx-raster` | FreeType License (FTL), chosen over its GPL-2.0 option; binds no image | permanent build tool | `deps.lock`; compiled by erXos's own compiler invocations |
| Root certificates | the trust store of every HTTPS client ([design-crypto.md](design-crypto.md#the-trust-store)) | none needed: facts, not a creative work | permanent | [config/trust/ORIGIN.md](../config/trust/ORIGIN.md) |
| BLAKE3, the official C implementation | the boot image's hashes and the entropy generator's mixing ([design-kernel.md](design-kernel.md#the-boot-image)) | used under Apache-2.0 WITH LLVM-exception | permanent | [kernel/crypto/blake3/ORIGIN.md](../kernel/crypto/blake3/ORIGIN.md) |
| FreeBSD's SHA-256 and ChaCha20 | the entropy generator's ChaCha20 and the C SHA-256 primitive | BSD-2-Clause; public domain | permanent | [sha2](../kernel/crypto/sha2/ORIGIN.md), [chacha20](../kernel/crypto/chacha20/ORIGIN.md) |
| The Pico SDK's PL011 SVD | the PL011's register layout | BSD-3-Clause | permanent | [hw/svd/pl011/ORIGIN.md](../hw/svd/pl011/ORIGIN.md) |
| Arm's machine-readable architecture specification | the facts in `hw/sysreg/aarch64.json` | BSD-3-Clause | permanent refresh input | [hw/sysreg/ORIGIN.md](../hw/sysreg/ORIGIN.md) |
| LLVM libc++, libc++abi and compiler-rt builtins | BeamAsm's C++ runtime (BeamAsm image only); the compiler's helper routines in target links | Apache-2.0 WITH LLVM-exception | permanent | built out of tree; the builtins by erXos's own build step |
| sDDF | the model for the split between a driver and its policy; the virtio drivers' oracle | BSD-2-Clause | reference only, nothing imported | read, never fetched into a build |
| FreeBSD's `netinet`, `netinet6`, `net` and `cc` | the decisions the TCP/IP stack translates into Erlang; the CUBIC test's oracle ([design-network-stack.md](design-network-stack.md#provenance-and-notices)) | BSD-2-Clause and BSD-3-Clause; `in_cksum.c` and `tailq_hash.*` never translated | permanent: the translation is erXos's code with FreeBSD's notices; the source is a reference | `deps.lock` |
| FreeBSD's USB, HID and BCM2711 PCIe sources | the decisions the USB stack and the PCIe bridge driver translate; the HID parser's oracle ([design-usb.md](design-usb.md#what-is-matched)) | BSD-2-Clause, ISC | permanent: reference | `deps.lock` |
| FreeBSD's termcap, signal, errno, termios and evdev sources | the oracles of `abi/termcap`, `abi/signals.txt`, `abi/errno.txt`, `abi/termios.txt` and the HID keyboard map | BSD | test data | `deps.lock` |
| FreeBSD's TCP test suite, and nplab's packetdrill | packet scripts whose verdicts erXos's stack must share with the FreeBSD test host | BSD-3-Clause; packetdrill GPL-2.0, built and run only on the test host, never linked | test data and tool | `deps.lock` |
| The FreeBSD test host: 16.0-CURRENT with vnet jails | the network stack's oracle ([design-network-stack.md](design-network-stack.md#verification)) | FreeBSD's | test machine | its verdict records live in the history repository |
| lwIP with lwip-contrib's `tapif` | the network stack's performance baseline ([design-network-stack.md](design-network-stack.md#benchmarks-and-targets)) | BSD-3-Clause | benchmark tool | `deps.lock`, built on the test host |
| A FreeBSD 15.1 QEMU image | the command shell's oracle guest | FreeBSD's | test tool | `deps.lock` |
| Alpine Linux 3.24.4's `virt` kernel and `musl-dev` | Linux's guest in the benchmark comparison under HVF; `erx_peer_bench` links statically against the C library ([design-bench.md](design-bench.md#linuxs-guest)) | GPL-2.0 (the kernel, run only as a black box in QEMU), MIT (musl) | test tool | `bench/linux/deps.lock`; booted without a network device |
| Raspberry Pi's stock 64-bit kernel 6.18.50-v8+ (`kernel8.img`), its `bcm2711-rpi-4-b.dtb` and `COPYING.linux`, of `raspberrypi/firmware` at `6f0881cba8be` | Linux on the Raspberry Pi 4 in the benchmark comparison, netbooted with the initramfs of Linux's guest ([design-bench.md](design-bench.md#linux-on-the-same-board)) | GPL-2.0 (run only as a black box on the board) | test tool | `bench/linux/deps.lock`; never in an erXos image or card |
| L4Re's repositories at the Fiasco fork's revision date, upstream Fiasco at that revision, and ipcbench | L4Re's guest in the benchmark comparison, built out of the tree by L4Re's own build system ([design-bench.md](design-bench.md#l4res-guest)) | MIT (the manifest; Fiasco but for its GPL and LGPL files, among them `jdb_object.cpp` and `kobject_rpc.h`), copyleft for parts of L4Re; ipcbench MIT where stated, its `measure.h` and build files unmarked, so it is built and run but never redistributed, and read only through a facts record | test tool | `bench/l4re/deps.lock`, fetched only by `tools/erx fetch --l4re`; built in the oracle's offline container; nothing of it enters the tree |
| Genode, its pre-compiled tool chain, and the kernels its guest is built for (`base-hw`, seL4, Fiasco.OC where Genode supports it) | Genode's guest in the benchmark comparison: `erx_peer_bench`'s `posix` rows through Genode's C library ([design-bench.md](design-bench.md#genodes-guest)) | AGPL-3.0, built and run only as a black box in a guest, never redistributed; its source is read by no agent | test tool | `bench/genode/deps.lock`, fetched only by `tools/erx fetch --genode`; built in an offline container on the x86-64 host of the remote QEMU cells; nothing of it enters the tree |
| The F2FS oracle and distribution guests: Linux, f2fs-tools, busybox, Ubuntu's cloud image, xfstests' `replay-log` | the reference for erXos's F2FS ([design-f2fs.md](design-f2fs.md#the-linux-oracle-guest)) | GPL, run only as black boxes in the guest | test tools | `deps.lock`; run without a network device |
| F2FS corpora: syzkaller's seeds, Fuchsia's test image, syzbot's images | hostile images for the F2FS readers and fuzz targets ([design-f2fs.md](design-f2fs.md#corpora)) | Apache-2.0; BSD-2-Clause; syzbot's unknown, never redistributed | test data, never committed | `deps.lock` |
| pjdfstest | POSIX file-system semantics over F2FS and littlefs ([design-f2fs.md](design-f2fs.md#posix-suites)) | BSD-2-Clause | test tool | `deps.lock` |
| `msantos/pkt` | the differential oracle for the stack's codecs | BSD-3-Clause | test tool | `deps.lock` |
| fsimg | writes and verifies every EROFS image; the FAT server's oracle | BSD-2-Clause | permanent host tool | `deps.lock`; built by `tools/erx build fsimg`, run as a subprocess |
| littlefs | the read-write file system of the data and vault partitions until erXos's F2FS, and, in development builds and test images, of drives' littlefs volumes, as its port | BSD-3-Clause | **stopgap**, shipped in 0.2 as a NIF under its [release contract](design-stopgap.md#release-contract); on a drive only as the port and in no release ([design-stopgap.md](design-stopgap.md#littlefs-on-a-drive)) | [littlefs/ORIGIN.md](../littlefs/ORIGIN.md) |
| OpenSSL 3.5 | OTP's `crypto`, `ssl` and `ssh`, never in the system domain's image ([design-crypto.md](design-crypto.md)); the vault's Argon2id, HKDF and AES-GCM | Apache-2.0 | permanent; a long-term-support series ([research](research-boards-storage.md#cryptography-libraries)) | [openssl/ORIGIN.md](../openssl/ORIGIN.md) |
| Text::Template | the template engine OpenSSL's `Configure` loads ([design-crypto.md](design-crypto.md#building-openssl)) | the terms of Perl 5 | permanent host tool | `deps.lock` |
| toybox, with `wak` as its awk | the UNIX commands of the shell and of programs | 0BSD | permanent | imported into `toybox/` as erXos's code, with an `ORIGIN.md` |
| Monocypher's Ed25519 | the small verifier of update and package signatures | used under BSD-2-Clause | permanent | [monocypher/ORIGIN.md](../monocypher/ORIGIN.md) |
| ctaes | constant-time AES for reference identities, without OpenSSL in the system domain | MIT | permanent | [ctaes/ORIGIN.md](../ctaes/ORIGIN.md) |
| Raspberry Pi firmware | starts the boards and loads the kernel | Broadcom's binary license ([research](research-boards-storage.md#the-raspberry-pi-firmware-license)) | permanent, board-specific | `deps.lock`, copied unmodified |
| CYW43455 WiFi firmware, NVRAM and CLM files | run by the Pi 4's WiFi chip ([design-wifi.md](design-wifi.md#the-chip)) | Cypress's binary license: object code only, unmodified, for Cypress chips, accepted by downloading ([design-wifi.md](design-wifi.md#sources)) | permanent, board-specific | `deps.lock`, copied unmodified with its license |
| wpa_supplicant and hostapd | the supplicant's differential oracle and the test access point ([design-wifi.md](design-wifi.md#verification)) | BSD-3-Clause | test tools | `deps.lock` |
| Cypress's `BCM4345C0.hcd` | the Pi 4's Bluetooth controller patch, loaded into the CYW43455's RAM at every bring-up ([design-bluetooth.md](design-bluetooth.md#the-bring-up)) | Cypress's Wireless Connectivity Devices Driver End User License Agreement (linux-firmware's `LICENSES/LICENCE.cypress`): object code only, unmodified, solely for use with Cypress chips; no notice condition on object code; accepted for this file | permanent, board-specific | `RPi-Distro/bluez-firmware` at `cdf61dc691a4`, `debian/firmware/broadcom/BCM4345C0.hcd`, SHA-256 `51c45e77ddad91a19e96dc8fb75295b2087c279940df2634b23baf71b6dea42c`, pinned in `deps.lock` with the license's text; a data file of `erx_bt` in the Pi 4's images |
| Raspberry Pi `usbboot` secure-boot images | an installation's secure boot ([design-platforms.md](design-platforms.md#trust-in-the-boot)) | Apache-2.0, firmware license for its binaries | permanent, run by the board's owner | `deps.lock` |
| TF-A's BL31 for the Pi 4 | the firmware calls that start CPUs and end the machine ([design-platforms.md](design-platforms.md#firmware)) | BSD-3-Clause | permanent, board-specific | `deps.lock` |
| The boards' device trees, from Linux | describe each board to the kernel | Pi 4 GPL-2.0, an accepted permanent copyleft dependency, shipped as a file of its own with its edited source and Linux's GPL-2.0 text; Pi 5 not permissive throughout in the Raspberry Pi kernel's tree (GPL-2.0-only includes and an unlicensed `rp1.dtsi`), which tree ships is open ([design-platforms.md](design-platforms.md#the-pi-5s-device-tree-and-its-license)) | permanent, board-specific | `deps.lock`, compiled with `dtc` |
| Host tools: LLVM clang, lld and binary tools (they build Fiasco and L4Re too), GNU make, QEMU, `dtc`, Ruby, Perl, Node.js and pnpm, GNU coreutils, git, host OTP 29.1.2, `b3sum`, herdtools7's `herd7`, Autoconf, Automake, Libtool | building, running and testing; release images are built with exactly LLVM 23.1.3 | various | tools | Homebrew; host OTP and `herd7` from pinned sources, `herd7` built with dune alone; the site workflow takes pnpm, its one executable, from the npm registry's `@pnpm/exe.linux-x64` at a pinned version and SHA-256 |
| OpenSSH's `ssh` and `ssh-keygen`, the host's own | the development login key and `tools/erx ssh` ([design-ssh.md](design-ssh.md#login-keys)) | OpenSSH's (unverified) | tools | the host's own, not pinned |
| TLA+ tools | protocol models ([design-verification.md](design-verification.md#model-suite-and-runner)) | MIT | permanent host tool | `deps.lock` |
| A Docker-compatible engine and the oracle's toolchain images | isolated stock OTP suites ([design-host-oracle.md](design-host-oracle.md)); the offline builds of L4Re and of stock OTP for Linux in the benchmark comparison, whose Erlang guest carries the image's glibc and the libraries OTP loads, run only in QEMU ([design-bench.md](design-bench.md#linuxs-erlang-guest)) | Apache-2.0; OrbStack's vendor license or colima's MIT | development tools | one image per platform (`linux/arm64`, `linux/amd64`) by digest in `deps.lock` |
| CBMC; awklog | pilots of bounded checking and relational manifest checks ([plan.md](plan.md#verification-work)) | BSD-4-Clause; BSD-2-Clause | host tools if adopted | Homebrew; `deps.lock` |
| libvterm; `vttest` | the terminal emulator's oracle and corpus ([design-display.md](design-display.md#the-oracle)) | MIT; MIT-style | test tools | `deps.lock` |
| musl's `libc-test` | the C library's oracle | MIT | test tool | `deps.lock` |
| 9front's `libmemdraw` and `libdraw`, unmodified | the display's pixel oracle ([design-display.md](design-display.md#verification-and-testing)) | MIT | test tool | `deps.lock`; 9front's mkfiles never run |
| plan9port's rc; the Open POSIX Test Suite; swtpm with libtpms | the shell's oracle, the POSIX-lite personality's oracle, the vault's test TPM | MIT; BSD-2-Clause and GPL-2.0-or-later; BSD-3-Clause | test tools, the suite only in test images | rc: [test/shell/rc/plan9port/ORIGIN.md](../test/shell/rc/plan9port/ORIGIN.md); the rest `deps.lock` or Homebrew |
| Bumble, with the packages of its declared dependencies that the scripts run import (pyee and typing_extensions; click joins with the apps that import it) | the Bluetooth test peer ([design-bluetooth.md](design-bluetooth.md#verification)) | Apache-2.0; MIT; PSF-2.0 | test tools | `deps.lock`: Bumble's tree at its tag's commit, the packages as PyPI's wheels, installed by `pip --no-index --require-hashes` into a virtual environment in `build/bumble` (`tools/lib/erx/bumble.rb`) |
| cmark-gfm | parses the book's Markdown for the website ([design-book-site.md](design-book-site.md#markdown-to-html)) | BSD-2-Clause | permanent build tool of the website; nothing of it is shipped | `deps.lock`; built out of tree with CMake into `build/book-tools/` and run as a subprocess |
| Source Serif 4, IBM Plex Mono, Archivo | the website's faces ([design-book-site.md](design-book-site.md#typography-and-look)) | OFL-1.1, font data only | permanent; shipped on the website beside their license texts | `deps.lock`, `file` entries |
| beautiful-mermaid, its flowchart, state and sequence renderers | draws the book's Mermaid diagrams to SVG for the website ([design-book-site.md](design-book-site.md#the-import)) | MIT | permanent build tool of the website; nothing of it is shipped | `tools/book/beautiful-mermaid/ORIGIN.md`, from the npm tarball |
| elkjs; entities | the layered layout and the entity decoding beautiful-mermaid calls | EPL-2.0, run unmodified in the build, nothing of it shipped; BSD-2-Clause | permanent build tools of the website | `tools/book/pnpm-lock.yaml`, install scripts off |
| v64, built with Closure Compiler | the website's in-browser console ([site/README.md](../site/README.md)) | BSD-2-Clause and MIT; Apache-2.0 | website only | `deps.lock`; built by `tools/build_site.rb` |
| doomgeneric (Doom), with Freedoom 0.13.0's `freedoom1.wad` | the Doom demo, `/bin/doom` of 0.1's published QEMU virt and Raspberry Pi 4 images | GPL-2.0-or-later; the WAD BSD-3-Clause; the image's NOTICES carries both texts, the GPL-2.0 text from the fork | example, 0.1's images only | the submodule `examples/doom/doom` of erXos's fork, fetched by `tools/erx fetch --example doom` with the WAD against its `deps.lock` hash ([ORIGIN.md](../examples/doom/ORIGIN.md)); no file of it enters erXos's tree |
| xterm.js 5.5.0 (`@xterm/xterm`) | the website console's terminal | MIT | website only | `site/pnpm-lock.yaml`; served from the site ([site/README.md](../site/README.md)) |

### Licenses and notices

erXos's own code is under the [BSD 2-Clause license](../LICENSE), copyright
Stanislav Sedov <stas@deglitch.com>. Code translated from Fiasco keeps its MIT
notice, per file and in `kernel/NOTICE-fiasco`, and comes only from files
whose effective license is permissive, judged by Fiasco's `LICENSE.spdx`,
the file's own notice and its upstream history, never by a header alone:
most of Fiasco's kernel sources carry no notice and take the MIT that
`LICENSE.spdx` declares for the kernel package, while a file's own
notice can say otherwise, as the GPL-2.0 notice of Fiasco's own
`kobject_rpc.h` does.
GPL-2.0 counts a translation as a modification, so nothing is translated
from a file under the GPL, or from one whose history shows code taken
from such a file. Code translated from FreeBSD's network stack keeps the
BSD notices of every file it derives from, per Erlang module and in
`erlang/apps/erx_net/NOTICE-freebsd`, and nothing is translated from
`netinet/in_cksum.c`, whose four-clause license keeps the advertising
clause, or from `tcp_stacks/tailq_hash.c` and `.h`, which carry no
license ([design-network-stack.md](design-network-stack.md#provenance-and-notices)).
Every imported tree keeps its license files. Two
mechanisms carry the conditions of the third-party licenses, and both
hold by construction:

* **Changed files say so.** Apache-2.0, OTP's license, and the Zlib
  license of asmjit and zlib require a changed file to carry a notice of
  the change. Each import's `ORIGIN.md` records the SHA-256 of every file
  as imported. A build check fails when a file under a directory that
  holds an `ORIGIN.md`, as every import does, differs from its recorded
  hash without erXos's change notice in its header comment, or is absent
  from the record without erXos's own notice; a changed file that cannot
  hold a comment, such as a regenerated bootstrap `.beam`, is named in its
  tree's `ORIGIN.md` instead. The set of changed files is derived from the
  record, so nobody keeps a list of them, and the rule covers every
  imported tree whatever its license, so no list of licenses decides where
  it applies.
* **Unknown provenance fails the build, and every image carries the
  notices of what it holds.** Every file that goes into an image has
  recorded provenance: a file erXos writes carries
  `SPDX-License-Identifier: BSD-2-Clause`; a file of an
  imported tree is under its tree's `ORIGIN.md`; a fetched artifact has
  its `deps.lock` entry; a generated file takes the provenance of the
  inputs its build rule records. A file outside every imported tree,
  erXos's own or generated, has the license of the one SPDX declaration
  line of its header, which must name every license a stock GNU grant or
  a notice listed in `config/imports/notices.txt` in it grants; its other
  comments are erXos's prose, not read as notices, except that one naming
  a copyleft license in other words records the file as unrecognised.
  Each file's license is recorded with its
  provenance: an imported file's entry in its `ORIGIN.md` holds the
  license a reviewed rule of its import's review assigned to exactly those
  bytes, pinned by their SHA-256; or the SPDX identifier of the one
  declaration line of its header (or of its `.license` sidecar), which
  holds nothing but a valid expression and its comment marks and must
  name every license the file's notices grant, any other declaration
  recording the file as unrecognised; or the license its own notices grant, where each
  notice, each comment block of the header and each comment block beside
  a notice is a stock GNU notice, a text listed by hash in the reviewed
  table `config/imports/notices.txt` (a pointer to the package's
  declaration counting only in the import it was reviewed in), or free of
  legal words, anything else recording the file as unrecognised, which no
  build admits; or, for a file with neither a declaration nor a notice,
  the license its tree's manifest declares for its package, such as
  Fiasco's `LICENSE.spdx`, or the license the import's review assigned,
  marked as reviewed; a fetched artifact's
  license is in its `deps.lock` entry. The packer takes each image's
  closure from the linker's map of every object and archive each
  executable links, the compiler's dependency files of each object, and
  its own list of every other file it packs (BEAM and application files,
  data, device-tree blobs, the contents of EROFS images); a slot's closure
  adds every file of its boot partition (the firmware, the board's
  firmware for starting CPUs with its linker map, the device trees and
  `config.txt`). The packer fails on any file of unknown provenance. It
  writes `NOTICES` into every boot image and every EROFS image: the
  license files of every contributing tree and artifact and, deduplicated,
  the header comment of every third-party file that carries a copyright
  notice, since BSD and MIT notices are per file; a file of erXos's whose
  SPDX line also names a third-party license, as a file translated from
  Fiasco does, counts as third-party for its notice. `NOTICES` is laid
  out as FreeBSD's and Debian's copyright files are: each distinct header
  comment once, under the files that carry it, their license and the
  license files they cite, and then each license file once, so a license
  that thousands of files share costs one copy. A license allowlist
  check fails the build when a closure holds a license outside it, so an
  excluded file, such as one of Fiasco's excluded GPL parts, cannot come
  back unnoticed. Beyond the closed table below, the allowlist admits a
copyleft license only for a file
  that the packer places on its own, outside every executable and every
  EROFS image: the Pi 4's device tree, which ships with its source beside
  it; it accepts the Raspberry Pi firmware's binary license for the
  files of a board's boot partition; it accepts Cypress's binary license
  for the CYW43455's firmware, NVRAM and CLM files in the WiFi
  application's `priv/firmware` of a Raspberry Pi image
  ([design-wifi.md](design-wifi.md#the-chip)), and Cypress's driver
  license for the Pi 4's Bluetooth patch, `BCM4345C0.hcd`, which the
  packer places unmodified as a data file of `erx_bt` and never links
  into an executable, with the license's text in the image's notices
  ([design-bluetooth.md](design-bluetooth.md#the-bring-up)), each for
  those files and no other. Test images, which are never
  distributed, have an allowlist of their own that adds the licenses of
  the test tools they carry, such as the Open POSIX Test Suite's
  GPL-2.0-or-later, and the packer refuses to mark a test image as a
release. The tree's `kobject_rpc.h` is erXos's MIT clean-room
replacement of Fiasco's GPL-2.0 original, and the kernel debugger's `jdb_object.cpp` is compiled only
into a kernel with the debugger: development kernels, the published
images' included, carry it by decision, and the release kernel leaves it
out ([design-fiasco.md](design-fiasco.md#the-releases-fiasco-build)).
One rule, `LicenseCheck`, decides which licenses a build takes, and
both the image check and the release kernel's link audit
([design-fiasco.md](design-fiasco.md#the-releases-fiasco-build)) apply
it. An input under a permissive license, such as the FSF All
Permissive License of l4re-core's `ldscripts/kip_addr.S`, enters every
build. A license that is not permissive enters only from one closed
table, `LicenseCheck::TABLE`, whose every row names one input by
its status, its label, its exact license and where the build reads
it, and the build kinds that take it: Doom's
archive, the `example`, under GPL-2.0-or-later at
`build/doom/libdoom.a`, in development builds only; and, from the
staged copy of Fiasco's inputs in `build/fiasco/inputs/`,
`jdb_object.cpp`, under GPL-2.0-only, in development builds only,
which goes out only in the website's images with its source offered.
Beyond the table a development build accepts only a local test image's
own packages (`package-local`), which no published image takes, so a
copyleft file that comes back into any other closure, a stopgap's or a
release component's included, fails the build. The only development images that
leave the project are the ones the website offers, the demo image and
the board cards, which the site serves with a link to the erXos source
they were built from, a release tag or commit, so what they carry goes
out with its source offered ([site/README.md](../site/README.md)). The same `NOTICES` sits beside the boot image in each
  slot's boot partition, with the license files of the firmware and device
  trees there.

## Tensions

* **Two schedulers.** The kernel and each runtime both decide; the six
  rules keep them from fighting, and the experiments measure what is left.
  Cross-domain priority is approximate: urgency carries it, not a kernel
  object per process, and a request to a service runs at the service's
  own urgency on the service's own grant.
* **A trusted base above the kernel.** The system domain is trusted by
  every domain for policy and for having built it. It runs in user mode,
  so its defects cannot reach other domains' memory, but it is part of
  what a user must trust, and a fault of its runtime resets the machine.
* **Services on their own grants.** No thread runs on another group's
  time, so there is no payer to derive, bound or audit; the price is that
  a saturated service slows every client of it together, and that
  sizing each service's grant is policy's job.
* **Drivers in Erlang.** A driver is a supervised process that can be
  inspected, traced and upgraded live, and a malicious device corrupts no
  memory; the price is that interrupt-to-handler latency passes through
  the runtime's scheduler, one ERTS instance per driver domain groups
  devices by configuration, and a fault in a device NIF ends the domain
  rather than a process.
* **A Fiasco kernel.** A kernel that is not erXos's stands in for erXos's
  kernel behind erXos's interface; replacing it is gated on parity over
  the part of the interface it carries, and the security closure requires
  erXos's kernel ([plan.md](plan.md)).
* **Owning the forks.** Not tracking upstream frees erXos to recombine
  ERTS, musl and Fiasco, and makes erXos responsible for every security
  fix in the parts it keeps.
* **Unconfined DMA.** On QEMU, virtio-mmio devices are unconfined, so the
  domains that drive them are trusted, and confined drivers use
  virtio-pci behind the IOMMU; the drivers of DMA devices on the
  Raspberry Pi boards are trusted, because the boards cannot confine
  them.
* **No confidentiality inside a domain.** Mutually distrusting code
  belongs in separate domains.
* **Shared mappings cohere within a session.** The session that maps a
  file shared holds its one object, so every fault resolves from its
  object and none waits on another domain; the price is that two sessions
  that map one file hold two copies, and that other sessions and readers
  see a session's stores only once it writes them back, as on a network
  file system ([design-files.md](design-files.md#shared-mappings)).
* **An interpreted system domain.** The trusted base holds no JIT and no
  C++; the price is the interpreter's speed for the system domain's own
  work, which is bounded control.
* **Memory dies with its budget.** Ending a domain is one destruction
  with nothing to drain; the price is that whatever must outlive a party
  has to be charged, from the start, to a budget that outlives it.

## Alternatives considered

**Nodes on a Linux-compatible layer.** Each domain would run an
unmodified ERTS node on a Linux-compatible layer, and domains would talk
through TCP distribution. The user rejected it as "a glorified container
runtime". erXos's domains are Erlang nodes too, with stock distribution
semantics between them, but on its own kernel: pids that print their
owner domain, connections the system domain makes between introduced
domains, each runtime's own funnel and export table as the authority
over who reaches its processes, one CPU authority over every runtime's
executors, and supervision and inspection that span domains
([design-domains.md](design-domains.md#alternatives-considered)).

**One node name with the domain id as creation.** Every domain would run
as an incarnation of one machine-wide node, distinguished by its creation,
so the whole machine would look like one node. It needs edits at several
sites of ERTS, which keys its node table by name and refuses a
connection to its own name, and it makes `node()`, `nodes()`,
`monitor_node` and the tools built on them mean something other than
stock does. erXos makes each domain a node of its own instead, and keeps
the domain id as the creation, so pids still name their owner domain.

**A gateway for distribution.** A gateway in the network domain could
make the whole machine one node to other machines, rewriting pids between
the two pid spaces: one connection per remote node and no domain
structure in sight. It costs a full term decoder and re-encoder on every
external message in the network domain, and a translation of links,
monitors and exits between the pid spaces, so each
exposed domain is a distribution node of its own instead
([Networking](#networking)).

**ERTS as the kernel.** An ERTS in kernel mode would be the machine's only
scheduler, with a scheduling record for every process of every domain. It
makes every process switch in a domain a kernel dispatch, puts a runtime
and a JIT in the kernel, and leaves no room for a second runtime. The user
chose generic two-level scheduling instead.

**A kernel thread per Erlang process.** The kernel would schedule every
process directly. Every spawn, switch and receive would enter the kernel,
and every process would hold a kernel object. E-S2 measures the cost on
the same kernel
([design-scheduler.md](design-scheduler.md#alternatives-considered)).

**Scheduler activations and upcalls.** The kernel would tell runtimes
about blocking and preemption by running their code. The systems that did
were abandoned for exactly that re-entrancy
([research](research-hierarchical-scheduling.md#negative-evidence)). erXos
keeps one upcall, Fiasco's vCPU interface, for POSIX signals to a
program's workers, which run no lightweight processes; no executor is ever
armed for it
([design-scheduler.md](design-scheduler.md#alternatives-considered)).

**Fiasco or seL4 kept permanently.** erXos keeps Fiasco's model, its
process model, gates, IRQ objects and vCPU interface included, but not its
code: keeping the fork would keep a C++ code base outside the kernel
construction rules (the stack proof, recursion only through `musttail`,
the chokepoint checks, generated register access), with erXos's additions
(budgets, groups, generations, memory objects)
grafted onto it; seL4's value is its proofs, which a modified fork voids,
and the user does not need them. A kernel of erXos's own, in C17 on
Fiasco's design, is smaller for erXos's needs and built under those rules
from its first line
([design-kernel.md](design-kernel.md#alternatives-considered)).

**Little Kernel as the base.** Its parts would have needed a microkernel
designed from scratch around them; Fiasco brings a proven capability
microkernel design to take ideas and know-how from.

**A router.** A third party, a native service in a domain of its own,
would carry every cross-domain frame, validate it and hold every
introduction on the sender's behalf: each domain would have one inbox and
one outbox, so ring memory would be constant per domain rather than two
lanes per introduced pair, and a parser defect would crash the router
instead of the receiving runtime. erXos does not take it: every frame
would be copied three times and cross up to three thread hops; message
authority would rest on a trusted base outside the domain, with its own
protocol, ring and fuzz target; a star makes one process's deadline a
machine-wide net split; and no flow in the design grants a name its
granter does not own, so a third party has nothing to decide that the
receiving runtime cannot decide from its own export table. Placing the
same router in the system domain would put every frame through the
system domain's scheduler, and in the kernel it would put an Erlang term
grammar in kernel mode
([design-domains.md](design-domains.md#alternatives-considered)).

**A separate native root task.** A small native program, started by the
kernel before the system domain, would build and end domains, keep the
table of them outside the system domain, and restart the system runtime
after a fault, so that configured services ride through such a fault with
their grants restored. It costs two system-domain instances overlapping
in one budget while the restart runs, identity and re-grant rules in
every configured registry, device reconciliation after the restart, and a
second trusted program with its own request protocol, ring and fuzz
target, and its fault would still panic the kernel. erXos takes the reset
instead, as OTP's `heart` does: the system domain is the root task, the
kernel's space tree ends every domain with it, and the domain library
sits behind one C interface in `liberx`, so a separate root task remains
a change behind that seam
([design-system.md](design-system.md#the-root-task)).

**Program domains.** Each native program would be a domain of its own,
with a domain id, a node identity, a connection to the system domain and
facets minted for it, so that a program could message any domain it was
introduced to directly. It costs a domain's creation per program start,
an id from the finite domain space per program, a broker hop through the
system domain for each request a program makes of its session, facets
that a program never asked for, and a program that holds grants' pids and
can be a confused deputy for a file server. A program's whole world is
its session, so erXos runs it as a port of its session in a sub-space,
reaching nothing but its channel and the memory its session mapped; an
Erlang command a program starts still runs in a command domain, since it
needs an ERTS
([design-programs.md](design-programs.md#alternatives-considered)).

**CPU donation.** A service would run a client's request on the client's
own time, by a loan through the IPC gate or a group the client donated,
so that per-client CPU attribution were exact and a service never spent
its own grant on a client. It costs a payer in every thread's record, a
chain rule through nested calls, floors so that a spent client cannot
stall a service holding a lock, charge words for workers, and a
scheduling dependency between domains that must be derived, bounded and
audited at every call. erXos keeps every thread on its own group's time:
a service runs on a capped grant policy sizes for its clients, admits per
client through that client's facet and lane, and reports attribution as
a statistic
([design-scheduler.md](design-scheduler.md#alternatives-considered)).

**C drivers.** Each driver would be native code in a domain of its own,
ported from sDDF or written after its model, with a control process in
the system domain to restart it. It is the proven shape, and a driver's
interrupt-to-handler latency would not pass through a runtime's
scheduler; but a parsing bug in a driver's view of its device would
corrupt memory instead of crashing a supervised process, every driver
would be a program outside the inspector's view of processes, and each
would need a runtime of its own for concurrency. erXos writes drivers in
Erlang over a device NIF that parses nothing, and admits a native driver
only where gate G9's measurement shows that the Erlang one misses the
device's timing or costs more than a stated fraction of its throughput,
as a row in the driver table with its measurement
([design-system.md](design-system.md#the-driver-table)).

**Everything in one address space with a verifier.** All code would run in
one space, isolated by a bytecode verifier, as Singularity isolated
processes by language safety. ERTS has no verifier and assumes trusted
code throughout, a verifier is itself attack surface, and speculative side
channels defeat language isolation within one address space.

**Linux binary compatibility, or a Linux virtual machine.** Running Linux
programs unmodified, through a system-call emulation or a guest kernel,
would avoid recompiling them. The user rejected both; programs are
recompiled against the POSIX-lite personality instead
([design-programs.md](design-programs.md#alternatives-considered)).

**A file's shared mappings served by its server through a kernel
pager.** Each file mapped shared would have one writable object at its
server, paged by the server through Fiasco's page-fault IPC: a worker's
fault on a page not yet supplied would call the server, under a deadline,
and every mapping of the file in any session would map the one object.
It buys coherence across sessions and with the file's reads and writes
everywhere. It costs a pager in the kernel, a fault that waits on another
domain with a deadline to choose and enforce, a claim protocol at every
server, and objects at the server that end with it under their mappers.
erXos has the session serve its programs' shared mappings instead, so
every fault resolves from its object
([design-files.md](design-files.md#alternatives-considered)).

**Budgets kept alive by their objects.** An object would keep the budget
that paid for it alive, as Fiasco's quotas do, so what a domain passed
on would outlive it. It costs a draining state for every ended domain,
a rule for who keeps its objects alive and a recovery of a dead budget's
objects, and a domain that keeps what it was passed holds its giver's
memory. erXos deletes everything charged to a budget with it, after
EROS's space banks, and charges what must outlive a party to a budget
that outlives it ([design-kernel.md](design-kernel.md#alternatives-considered)).

**Kernel calls that copy from user addresses.** A call could take a
pointer to a request in the caller's memory and copy it in once before
validating it. It needs user-copy functions, address validation and an
architecture's guard on the window in which the kernel may touch user
memory, and every new call is one more place to get the copy discipline
right. erXos's kernel never loads or stores through a user address:
registers, UTCB fields read once through generated accessors, memory
objects, and for umtx a translation through the caller's page table
([design-kernel.md](design-kernel.md#alternatives-considered)).

**A JIT in the system domain.** The system domain would run the BeamAsm
image like every other domain, so one runtime image would be exercised
everywhere. It puts a JIT, a view that is writable before it is
executable and C++ into the trusted base, for work that is bounded
control. erXos runs the interpreter there
([design-runtime.md](design-runtime.md#beamasm)).

**An erXos variant of 9P.** An operation list of erXos's own, shaped like
9P, would fit erXos's frames exactly. It forgoes the standard's clients
and servers at the machine's edges and its semantics as an oracle; erXos
speaks 9P2000.L, as terms inside the machine and as its messages at the
edges ([design-files.md](design-files.md#the-file-protocol)).

**A progress record for updates.** The update service would record each
update's progress, from writing the spare to its commit or failure,
beside the boot-selection record. It adds a second record to keep
consistent with the first across power cuts and to order against the
vault's checkpoint at an ordered end. erXos decides a spare's
completeness by verifying it against its update manifest at boot, so
the boot-selection record's two states are the whole of an update's
state ([design-storage.md](design-storage.md#system-updates)).

**Pseudo-terminals in the kernel, and a copy-on-write `fork`.** The second
tier gives programs `fork`, pseudo-terminals, process groups and sessions
without either. A line discipline in the kernel would put terminal state
in kernel mode for no gain in protection, so the line discipline is a pure
state machine in the session; and `fork` is an eager copy of the sub-space
by its session, which keeps private memory's rule that each page is mapped
once, until gate GQ shows whether a copy-on-write path over the kernel's
copy-on-write children is worth its cost
([design-programs.md](design-programs.md#alternatives-considered)).

**AtomVM, a purpose-built VM, Ling's approach, or Linux underneath
(Nerves).** They lost because erXos chose ERTS, whose semantics,
performance and tools are what erXos is for, and because a conventional
kernel running an Erlang node does not make Erlang processes the system's
processes.

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| Two-level scheduling misses priority or latency targets that a kernel thread per process would meet | medium | high | E-S1, E-S2 and E-S8 on the same kernel before user domains build on it; urgency publication and the receive boost; the plain configuration as the fallback |
| Writing erXos's kernel takes longer than the plan assumes | medium | high | Phase 1b carries the user-facing system on Fiasco behind the unchanged interface, so the system is usable whatever the kernel's date, and only what needs erXos's kernel's guarantees waits for it; a pilot calibrates the effort before the kernel is written in full |
| erXos's modifications to Fiasco grow large | medium | medium | Fiasco stays near-stock: the backend carries only the part of the interface that Phase 1's system uses, refuses the rest with `ERX_ENOTSUP`, and builds no kernel mechanism in user mode |
| Cross-domain messaging costs too much for real applications | medium | medium | E-D1 before user domains build on it; doorbell batching; lazy decode; a lane is already a direct ring between the two parties |
| An Erlang driver misses a device's timing, or costs more than a stated fraction of its throughput | medium | medium | gate G9 measures latency and throughput per device class and decides batching; an exception is a row in the driver table with its measurement, run as a native shim behind the same interface |
| Owning the security fixes of ERTS, musl and Fiasco falls behind | high | high | a recurring review of each upstream's advisories against the kept parts; the funnel's positive grammar narrows what any decoder bug can be reached with |
| The network stack or the file systems, in Erlang, are too slow for the boards | medium | medium | the packet-path prototype measured on QEMU as a baseline, and gate GK3 deciding on erXos's kernel, with TCP's fast path in native code only if those numbers ask; per-byte work in C primitives; the file-system and network benchmarks at G12 to G14 |
| Recombinations break Erlang semantics subtly | medium | high | a fast subset of the oracle on every change and the full suites at every major change; deterministic mode for reproduction |
| HVF lacks something the design assumes (MSIs through QEMU `virt`'s MSI frame, timer behaviour) | medium | medium | virtio-mmio with ordinary interrupts wherever no driver for the MSI frame exists; every suite runs under HVF |

Further decisions, each with its detail in the document named:

* **Translating from Fiasco.** erXos's kernel translates or copies code
  only from Fiasco files whose effective license is permissive, judged by
  `LICENSE.spdx`, the file's own notice and its upstream history, so
  nothing comes from a GPL file or one whose history shows GPL code;
  erXos's kernel needs nothing of `kobject_rpc.h` or `jdb_object.cpp`
  ([Licenses and notices](#licenses-and-notices),
  [design-fiasco.md](design-fiasco.md#the-releases-fiasco-build)).
* **Login credentials.** The vault checks a passphrase by opening one of
  the principal's credential slots, with Argon2id at RFC 9106's second
  recommended option as the ceiling until the login measurements; first
  enrolment only at the console's UART
  ([design-system.md](design-system.md#the-vault)).
* **A device secret through the root task**, derived from a board's OTP
  key at boot and reaching only the vault's domain, as the sealing page; a
  departure from Fiasco the L4 lineage records
  ([design-platforms.md](design-platforms.md#device-secrets),
  [design-system.md](design-system.md#the-vault)).
* **The vault's partition in the MBR's extended partition**, before the
  data partition ([design-storage.md](design-storage.md#data-model)).
* **Secure boot as an installation option** on the boards that offer it
  ([design-platforms.md](design-platforms.md#trust-in-the-boot)).
* **Late errors on the Raspberry Pi 4** stop the presumed thread and mark
  the record as presumed
  ([design-kernel.md](design-kernel.md#interrupts-time-and-entropy)).
* **An own budget and an outer budget per domain**: the own budget pays
  for what the domain alone maps, the outer budget, through one child
  budget per connection, for what others map; a survivor that never lets
  go pins at most its own `connections` quota plus the dead domain's
  outer budget ([design-system.md](design-system.md#ending-a-domain),
  [design-domains.md](design-domains.md#connections)).
* **Programs hang from anchors**, so a program's children survive its
  `exec` and none outlives its starter, and **a program record outlives
  its images** in its handler
  ([design-programs.md](design-programs.md#a-programs-end),
  [design-programs.md](design-programs.md#the-handler)).
* **Each domain's pid is a process of its own**, linked to the domain
  service and the domain's correspondent for the connection protocol
  ([design-system.md](design-system.md#ending-a-domain),
  [design-domains.md](design-domains.md#connections)).
* **A deletion closes first**, invalidating the existence lock before
  emptying slots, a departure of order from Fiasco
  ([design-kernel.md](design-kernel.md#closing-and-deleting)).
* **`CAPS` stays with a space and its creator**
  ([design-kernel.md](design-kernel.md#invariants), K17).
* **An image change is the session's alone**: `exec` makes the channel
  anew ([design-programs.md](design-programs.md#the-second-tier)).
* **Requester identity comes from fixed buses**: a device's DMA is
  confined only where the fabric fixes its requester id
  ([design-kernel.md](design-kernel.md#dma-and-the-iommu)).
* **Every requested end has one owner**, which latches the ending record
  before irreversible preparation and never half-resumes the system
  ([design-system.md](design-system.md#ending-a-domain)).
* **The watchdog's period and deadlines**, by default a 1 s period, a 5 s
  deadline after each pet and a 60 s boot deadline, set by
  `erx.watchdog=P,D,B` ([design-kernel.md](design-kernel.md#the-watchdog),
  [design-platforms.md](design-platforms.md#the-watchdog)).
* **A program's group is a child of its session's**, and job control
  pauses the image, never the group
  ([design-programs.md](design-programs.md#a-program-is-a-port)).
* **Capacity names a run** of CPUs whose shares sum to at most one CPU on
  each ([design-system.md](design-system.md#resource-policy)).

Decided, and recorded where each applies, beyond the
[Decisions](#decisions) table:

* Holds act at the kernel's one return check, so a pause never interrupts
  kernel work ([design-kernel.md](design-kernel.md#threads-and-faults),
  K30).
* A fork's copy runs on a copier in the program's own group, one per
  parent at a time ([design-programs.md](design-programs.md#the-second-tier)).
* erXos's F2FS gets a legal review of its clean room before any
  distribution includes it, and a data partition is never converted in
  place ([design-storage.md](design-storage.md#read-write-storage)).
* erXos's kernel keeps Fiasco's two object locks
  ([design-kernel.md](design-kernel.md#l4-lineage)).
* A program's socket is an open-file description of its session, and a
  file or pipe end passed with `SCM_RIGHTS` outlives its sender as on
  UNIX ([design-network-stack.md](design-network-stack.md#the-interface-towards-posix-programs),
  [design-programs.md](design-programs.md#passing-descriptors)).
* A `SIGCONT` the `kill` rules let through lifts job control's causes and
  no other hold ([design-system.md](design-system.md#creating-a-domain)).
* `fork` and `exec` are absent from the first tier, where calling them
  fails to link ([design-programs.md](design-programs.md#the-second-tier)).
* The release process, the custody of the release signing key included,
  is outside this design ([plan.md](plan.md#beyond-the-plan)).

## References

* The research records of this repository, each dated, with its own
  sources: [hierarchical scheduling](research-hierarchical-scheduling.md),
  [ERTS internals](research-erts-internals.md),
  [ERTS's host requirements](research-erts-host.md),
  [prior art](research-prior-art.md),
  [kernel bases](research-kernel-bases.md),
  [C libraries](research-c-library.md),
  [QEMU and runtime baselines](research-baselines.md),
  [boards, network stacks and file systems](research-boards-storage.md),
  [architecture evidence](research-architecture.md),
  [AArch64 features and DMA contracts](research-hardware-contracts.md),
  [stock OTP 29.1.2 reference runs](research-otp-reference-runs.md),
  [FreeBSD's network stack mapped to Erlang](research-freebsd-net-mapping.md),
  [the CBMC pilot](research-cbmc-pilot.md),
  [BL31 on QEMU's raspi4b](research-rpi4-bl31-qemu.md),
  [the first Raspberry Pi 4 board pass](research-rpi4-board-pass.md),
  [the Raspberry Pi 4 header probe](research-rpi4-header-probe.md),
  [what QEMU's raspi4b keeps of the pin controller](research-qemu-raspi4b-pins.md),
  [the BCM2711's SD controller](research-sdhci-bcm2711.md),
  [QEMU's raspi4b SD controller with a card](research-sdhci-qemu-model.md),
  [the BCM2711's Ethernet controller, GENET v5](research-genet-bcm2711.md),
  [QEMU's virtio-input device](research-virtio-input-qemu.md),
  [the BCM2711's PCIe bridge and the VL805](research-brcmstb-pcie.md),
  [the Raspberry Pi 4's WiFi slot](research-wifi-pi4.md).
* Erlang/OTP 29.1.2 source, `otp_src_29.1.2.tar.gz`, SHA-256
  `c79966661e35fe4aff8ec003db63682e3b33b10b672220d51bf93c0a9244b049`,
  read 2026-10-29.
* Fiasco, https://github.com/kernkonzept/fiasco at commit `50bbe8a9` (the
  proposal links https://github.com/L4Re/fiasco), and `l4re-core` at
  commit `e2e2d5af`, read 2026-10-29.
* musl 1.2.6, `musl-1.2.6.tar.gz`, as recorded with its SHA-256 in
  [research-c-library.md](research-c-library.md).
* Arm, "Release notes for BSD license JSON in A profile architecture",
  document 110173, https://developer.arm.com/documentation/110173/;
  Arm, CMSIS-SVD format description, schema 1.3. The architecture's
  manuals are cited in
  [design-arch-aarch64.md](design-arch-aarch64.md#references), and the
  platforms' in [design-platforms.md](design-platforms.md#references).
* QEMU 11.1 `virt` machine documentation and `hw/arm/virt.c`, read
  2026-10-29.
* The proposal "erXos -- Erlang-native microkernel with generic runtime
  scheduling", v0.2, 29 October 2026, and its references, as covered in
  [research-hierarchical-scheduling.md](research-hierarchical-scheduling.md).
