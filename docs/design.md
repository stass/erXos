# erXos: architecture

The [build and host tooling design](design-build.md) defines process
deadlines, source provenance and the build's evidence boundaries.
The [host oracle design](design-host-oracle.md) defines isolated Linux suite
execution, its container lifetime and its separate native host baselines.
The [hardware generation design](design-hardware-generation.md) defines
register inputs, terminal tables and their generation checks.

> In erXos, Erlang's process is the operating system's process: one process
> space, one message system and one view of identity, supervision and
> inspection span every runtime, and one CPU authority gives each runtime
> the time its grant allows.

erXos is a cross-platform operating system built around running Erlang
applications, on AArch64 first. Its kernel is a capability microkernel of its own, written
in C17 on the design and know-how of L4Re's Fiasco. The kernel knows
threads, groups of threads, memory, capabilities and interrupts, and
nothing of Erlang. It allocates CPU time to native threads and to
**runtime groups**, and each runtime, ERTS first, schedules its own
lightweight processes within its group's **grant**, switching between them
without entering the kernel. Every runtime runs in user mode, including
the one that runs the system services, which are mostly Erlang. Across
runtimes, a pid names its owner domain by construction, every signal
between domains travels on a **connection** the system domain made and is
checked by the receiving runtime's own **funnel**, and process links,
monitors and exits keep Erlang's semantics, so the whole machine is one
Erlang system.
Everything is inspectable from an Erlang shell on the serial console or
from the development host, down to kernel objects and the line of source a
process is executing. Until erXos's kernel is written, a near-stock Fiasco
stands in for it behind the same interface, carrying the part of it that
Phase 1's system uses.

Decisions every reader must know:

* **Two levels of scheduling, one CPU authority.** The kernel schedules
  threads by urgency within their groups' grants; a runtime schedules its
  processes on its **executors**, the threads its group pays for. Six
  rules keep the two levels from fighting: an executor is an ordinary
  preemptible thread; a preemption never runs runtime code, it only
  resumes the executor later; wakeups and capacity changes are events that
  coalesce, are never lost and are taken at the runtime's safe points; an
  executor never blocks except to park, or on a lock inside its own
  domain; the kernel enforces every grant whatever a runtime reports; and
  there is no donation: every thread is charged to its own group. The
  mechanisms behind them, IRQ objects as doorbells on a group's ready list
  and epochs that order wakes against parks, are in
  [design-scheduler.md](design-scheduler.md).
* **erXos's own kernel, on Fiasco's design, with a near-stock Fiasco as the
  stopgap.** The kernel keeps Fiasco's model wherever erXos needs nothing
  else, among it capabilities in a table per space, IPC gates bound to
  threads, messages in each thread's registers with capabilities passed at
  the rendezvous, IRQ objects as doorbells, the vCPU interface for
  signals, a kernel stack per thread, and tasks that any holder of a
  factory may create ([Kernel](#kernel)); each departure is listed with
  its reason in its [L4 lineage](design-kernel.md#l4-lineage). The kernel
  interface is erXos's from day one, generated from `abi/erx_abi.txt`. The
  kernel never loads or stores through an address in a domain's memory:
  an argument is a register, a field of the calling thread's UTCB, which
  the kernel reads once through generated accessors, or a memory window,
  a memory capability with an offset and a length, which the kernel
  reaches only through its two window accessors over its own mapping of
  the object; umtx alone takes an address, which the kernel translates
  through the caller's page table to read the word through its own
  direct map, refusing an address that translates to memory the direct
  map does not cover.
  Deleting a budget deletes every object charged to it, as EROS's space
  banks do, so ending a domain is one destruction. The
  near-stock Fiasco under `liberx`'s Fiasco backend carries none of these
  semantics, and erXos's C17 kernel boots Phase 1's system and replaces it
  before the security closure milestone, carrying alone every mechanism
  beyond that system
  ([design-kernel.md](design-kernel.md#the-current-implementation-the-modified-fiasco)).
* **Every runtime in user mode.** ERTS runs in every Erlang domain, the
  system domain included, from one of two runtime images: the system
  domain runs the interpreter, whose image holds no JIT and no C++, and
  every other domain the BeamAsm image by default; native programs use
  `liberx`, the only way to the kernel, and run as ports of their
  sessions ([design-runtime.md](design-runtime.md)).
* **Every domain is a node; a pid carries its owner; authority is
  separate.** Each domain is an Erlang node with a name of its own, its
  identifier at the machine's host name, such as `web@erxos`, and its
  domain id as its node's creation, so a pid names its owner domain and is
  never reused, and a connection between two domains is a distribution
  connection between two nodes in stock ERTS's sense. A domain
  messages, links to, monitors, exits or spawns into another domain's
  process only when that process's own runtime has exported the pid to
  it, which happens when the owner hands the pid out in a frame, when the
  domain spawned the process, or by an explicit export; pids of other
  domains in a payload remain unchanged data, and privileged service
  admissions take explicit authority apart from that data; the signals
  that answer or undo a link or monitor need none, since they reach only
  relations the sender's own processes hold
  ([design-domains.md](design-domains.md#exports)).
* **Mechanism in the kernel; policy, and the mechanism for domains, in the
  system domain.** The kernel enforces memory, CPU and capabilities. The
  system domain is the root task: a C17 domain library in `liberx` builds
  and ends domains, and Erlang services decide who gets what
  ([design-system.md](design-system.md#the-root-task)). What the machine
  is configured to run is one system manifest, which the build checks and
  packs into the boot image and from which the boot sequence, the domain
  service and the device service all read
  ([design-system.md](design-system.md#the-manifest)). Who may signal a
  domain's processes is decided by that domain's own runtime, in its
  funnel and its export table, and by nothing else.
* **UNIX where it pays, never as the base.** A domain sees files through
  its own namespace, a table of file servers in which a path is the face
  of a capability, after Plan 9, and every file server speaks 9P2000.L; a
  file that a session's programs map shared is one memory object that
  the session holds and maps into each of them; a command shell with rc's
  language runs
  builtins, Erlang commands and programs in one command namespace; and
  native programs run as ports of their sessions, in sub-spaces, with a
  POSIX-lite personality, growing toward QNX's with `fork`, `exec`, shared
  libraries and terminals, and holding only what their starter handed
  them
  ([design-files.md](design-files.md),
  [design-shell.md](design-shell.md),
  [design-programs.md](design-programs.md#a-program-is-a-port)).
* **Design first, then fit what exists.** ERTS, musl and Fiasco are parts
  bins: erXos owns their code, takes them apart and recombines them. The
  design is drawn first, unconstrained by what that code does today; how
  little of it must change is worked out afterwards
  ([design-runtime.md](design-runtime.md#the-inventory)).
* **Correct by construction in the code itself.** Decisions are pure
  functions with effects at the edge; the ABI and the hardware's registers
  each have one source from which code is generated; every "only X may do
  Y" rule is a build check; the kernel's stacks are bounded by proof
  ([Correct by construction in code](#correct-by-construction-in-code)).
* **Measure the cooperation.** The plain configuration, executors as
  ordinary threads with no cooperation between the two levels, is the
  baseline; every cooperation feature has an off switch and earns its
  place by experiment ([plan.md](plan.md)).

## Document map

Start with [overview.md](overview.md) for a compact introduction to the
architecture, major features, choices and influences. This document owns
decisions shared across subsystems.
The subsystem designs below define their contracts within that architecture;
the architecture and platform bindings supply the hardware-specific details.
The roadmap owns sequencing and acceptance gates. Open defects belong in
[TODO.md](../TODO.md); unadopted alternatives belong in
[todo-simplification.md](todo-simplification.md). Research records supply
evidence, not additional design contracts.

| Document | Role |
| --- | --- |
| [overview.md](overview.md) | a reader's introduction to the design; the architecture and subsystem documents define the contracts |
| this document | the architecture and every decision that constrains more than one subsystem |
| [design-kernel.md](design-kernel.md) | the kernel: objects and capabilities, budgets, memory, spaces and sub-spaces, threads, IPC gates, IRQ objects, umtx, vCPU upcalls, interrupts, boot, the ABI, its L4 lineage, and the near-stock Fiasco behind the same interface |
| [design-stopgap.md](design-stopgap.md) | the stopgap: `liberx`'s Fiasco backend over a near-stock Fiasco in Phase 1: the call table, the root's ownership of every kernel object, the root service, memory through the pool window, threads, exit and readiness, the boot handoff, the Phase 1 manifest check, the console, and what Phase 1 defers and where it lands |
| [design-arch-aarch64.md](design-arch-aarch64.md) | the AArch64 binding: how the architecture provides each item of the kernel's port contract, its system-call convention, translation tables, IOMMU, firmware calls and speculation mitigations, and the terms that nothing generic uses |
| [design-platforms.md](design-platforms.md) | the platform binding: QEMU `virt`, the Raspberry Pi 4 Model B and the Raspberry Pi 5, with their interrupt controllers and MSI frames, firmware, boot, the early console, the system manifest per platform, DMA, entropy, watchdogs, trial requests, device secrets and trust in the boot |
| [design-scheduler.md](design-scheduler.md) | the first level: groups, grants, urgency, park and wake, deferred preemption, service work on a service's own grant, the runtime contract, and the experiments that tune them |
| [design-runtime.md](design-runtime.md) | the runtimes in user mode: ERTS taken apart and recombined, its adapter to the contract, connections as the carrier beneath its cross-domain path, programs as ports, the device NIF, the interpreter and BeamAsm images, the C library seam, `liberx` with its root-task entry and system layer |
| [design-shared-code.md](design-shared-code.md) | shared loaded code: one image of the preloaded modules and the applications every domain release ships, made at build time by `runtimes/emu` itself under QEMU, packed into the boot image and mapped read-only at the same addresses into every granted domain that runs `runtimes/emu`, with per-domain atom and catch prefixes and cells for exports and funs, origin by address, and one preparation interface that privatises a module before any write to its code |
| [design-programs.md](design-programs.md) | native programs and the POSIX-lite personality: a program as a port of its session, the channel and the handler, the startup message, executables and `rc` as programs, descriptors, signals, job control, toybox, and the second tier |
| [design-pipes.md](design-pipes.md) | pipes in user space: rings in memory the session's pipe server makes and maps, IRQ objects as doorbells, and each session's pipe server |
| [design-domains.md](design-domains.md) | domains, the pid space, connections and lanes, exports, the funnel at the receiver, frames, flow control, facets, links and exits across domains, ERTS's integration |
| [design-system.md](design-system.md) | the root task and boot, the system manifest, the domain library, domain creation and ending, authority, resource policy, devices and drivers with the driver table, the system services, identifiers, the vault |
| [design-files.md](design-files.md) | namespaces, the file protocol (9P2000.L), file servers, and shared mappings served by the session |
| [design-tmp.md](design-tmp.md) | the RAM file system at `/tmp`: an `erx_fs` server in each domain over one tree process, its charges against the `tmp` cap, and its POSIX semantics |
| [design-storage.md](design-storage.md) | partitions, the boot image, EROFS images and their Erlang reader, the data partition and the vault's partition, read-write storage in Erlang, FAT for removable media and exchange, system updates with A/B slots and trials |
| [design-network-stack.md](design-network-stack.md) | erXos's TCP/IP stack: FreeBSD's default stack, pinned at a FreeBSD 16 commit, translated into Erlang, the process structure and packet path, the effect layer and the four seams that let it run unchanged on stock OTP outside erXos, as a package of its own, grants and sockets, the interfaces to Erlang and POSIX programs, verification against FreeBSD and stock OTP; this document's [Networking](#networking) holds the choices that bound it |
| [design-network-fastpath.md](design-network-fastpath.md) | the stack's performance: runs of segments that the copy into the medium cuts into frames, received segments merged before classification by FreeBSD's LRO rule, the lean per-segment step, batching per hop, the tap transport as a NIF, copies per path, and the benchmarks against lwIP |
| [design-live.md](design-live.md) | the live machine: console and ttys, attributed text, inspector and `/proc`, tracing, code from the host and the code store, the host link |
| [design-shell.md](design-shell.md) | the command shell: rc's language, the command namespace, pipelines of text and the commands that follow FreeBSD's, starting programs, `rc` as a program, job control |
| [design-display.md](design-display.md) | the display: a display domain serving windows as files, Plan 9's draw protocol with one connection per window, the window system's overlapping and single policies, the terminal `erx_vt` and `erx_term` as a program of the user's session, widget trees as terms with events as messages behind one renderer behaviour (Erlang, and LVGL as a stopgap), presentations of typed values, and kiosks, dashboards and glasses, where a kiosk under LVGL has one screen owner, `erx_ui_kiosk`, and no window system |
| [design-web.md](design-web.md) | the web: a TypeScript and React client in the browser that receives only typed data over one WebSocket protocol generated from `abi/protocols/web.txt`, records, logs and traces fetched in the principal's session with its own facets, the browser as one more display behind the widget interface, rendering for its own medium and chosen by name, URLs as inspector paths and presentation URIs, two front ends for one protocol (`tools/erx web` over the host link, cowboy in the web domain) |
| [design-generation.md](design-generation.md) | one-source interface bindings, inspection and diagnostics, catalogs, reference tables and test scaffolding |
| [design-abi.md](design-abi.md) | declaration grammar, validated layouts, bounded binary readers, numeric assignments and generated-output inventory |
| [design-verification.md](design-verification.md) | pure protocol cores, independent TLA+/TLC models, model-to-code evidence, and verification tool boundaries |
| [plan.md](plan.md) | milestones, exit criteria and decision gates |
| [style.md](style.md) | code style |
| [todo-simplification.md](todo-simplification.md) | unadopted alternatives, their costs and decision evidence |
| [TODO.md](../TODO.md) | open work outside the roadmap |
| research records | point-in-time evidence: [hierarchical scheduling](research-hierarchical-scheduling.md), [ERTS internals](research-erts-internals.md), [ERTS's host requirements](research-erts-host.md), [prior art](research-prior-art.md), [kernel bases](research-kernel-bases.md), [C libraries](research-c-library.md), [QEMU and runtime baselines](research-baselines.md), [boards, network stacks and file systems](research-boards-storage.md), [architecture evidence](research-architecture.md), [AArch64 features and DMA contracts](research-hardware-contracts.md), [stock OTP 29.1.2 reference runs](research-otp-reference-runs.md), [FreeBSD's network stack mapped to Erlang](research-freebsd-net-mapping.md), [the aloha stack](research-aloha.md), [the CBMC pilot](research-cbmc-pilot.md), [the Track K pilot's timing](research-track-k-pilot.md) |

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
| **connection**, **lane** | the one transport between two domains that have been introduced: two lanes, one per direction, made by the system domain, which alone holds the delete right to their objects; one direction of a connection: a **ring** in a memory object that the producer alone writes, a **reader page** that the consumer alone writes, and a **doorbell**, an IRQ object that the system domain binds to the consumer's group and that the producer holds with `TRIGGER` alone; each lane is charged to a child budget, one per connection, of the outer budget of the domain that reads it, and both lanes of a domain's connection to the system domain to that domain's | [design-domains.md](design-domains.md#connections) |
| **node name** | a domain's name as an Erlang node: its identifier at the machine's host name, such as `web@erxos` or `system@erxos`, with the domain id as the node's creation | [design-domains.md](design-domains.md#domain-ids-pids-and-references) |
| **own budget**, **outer budget** | the two budgets the domain library carves side by side for each domain from the same parent: the own budget pays for what the domain alone maps and is destroyed at once when the domain ends; the outer budget pays for whatever another domain maps, each connection through a child budget of its own: the lanes the domain reads with their doorbells, and both lanes of its connection to the system domain; only its crash area is charged to the outer budget directly, so the outer budget holds exactly its connections' child budgets and its crash area; the domain holds no capability to its outer budget, and the system domain destroys each child once both parties to its connection have let go, and the outer budget once no child remains and the crash record is read | [design-system.md](design-system.md#ending-a-domain) |
| **frame**, **funnel** | one signal crossing a domain boundary, on a lane; the receiving runtime's one reader of its lanes, a C17 library in `liberx`, which copies a frame out of the ring once, validates its structure and its authority against the domain's own export table, and then decodes it, in safe mode in the system domain | [design-domains.md](design-domains.md#the-funnel) |
| **export**, **export table** | one of a domain's own pids or aliases, or its own name, made reachable to one peer domain with rights: `send` (messages, alias sends, monitors) when the owner hands the name out in a frame, `send`, `link` and `exit` on a child the peer spawned, and any rights, `spawn` on the domain's name and `introduce` on its domain pid among them, that the owner sets with `erx:export/3`; the holders of each name, kept on the name's own record, which the domain's runtime owns and alone writes | [design-domains.md](design-domains.md#exports) |
| **facet**, **handle** | a process of the system domain that stands for one grant to one grantee domain, and acts only for its grantee, the domain whose lane its requests arrive on; a value a facet mints from its own scope, which privileged service helpers take in place of bare request names | [design-domains.md](design-domains.md#facets), [design-domains.md](design-domains.md#authority) |
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
| **driver**, **device NIF**, **device shim** | an Erlang process under a supervisor, in a domain that holds its device's capabilities; the one module, `erx_device`, BIFs for what a driver does per access or per interrupt and a NIF for the rest, through which a driver reads and writes registers by name, posts and completes descriptors, takes buffers from a DMA-mapped pool, receives each completed buffer's bytes as a fresh binary, never one over the pool, and acknowledges interrupts; the NIF's C, the thin C under every driver, which parses nothing a device wrote | [design-system.md](design-system.md#drivers), [design-runtime.md](design-runtime.md#the-device-nif) |
| **native shim** | any native driver code other than the device NIF, a stopgap or third-party driver included, which runs as a sub-space port of its driver's domain and exists only as a row of the driver table | [design-system.md](design-system.md#drivers) |
| **devices domain**, **PCIe domain**, **driver table** | the domain that holds the slow devices other than the UARTs of the console and the host link, and no configuration space, outside the trusted base without exception; the one domain, `pcie` in the system manifest and the node `pcie@erxos`, that holds PCIe configuration space and nothing else and runs the PCIe enumerator, in the trusted base whole; the table in [design-system.md](design-system.md#the-driver-table) of every native shim, each a row with what justifies it | [design-system.md](design-system.md#devices) |
| **watchdog**, **crash record**, **machine reset** | the kernel's one watchdog, armed at the root task's start and petted by the system domain's watchdog process once the services it lists have answered; what the kernel writes before the machine ends, brief in release builds (cause, program counter, fault address, build, boot value and its slot, uptime, time since the last pet) and full in development builds, into a region that survives a warm reset where the platform has one, else to the console and the log, shown at the next boot only to the system shell; how a fault of the system domain, a missed watchdog or `erx.panic` ends the machine, through the firmware interface | [design-kernel.md](design-kernel.md#the-watchdog), [design-system.md](design-system.md#the-root-task) |
| **boot image** | the archive that holds everything the machine starts with | [design-kernel.md](design-kernel.md#the-boot-image) |
| **bootable file** | the one file a loader boots: the first stage, erXos's kernel or the stopgap's `bootstrap`, with the boot image inside it | [design-kernel.md](design-kernel.md#the-bootable-file) |
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
owns it:

| Invariant | Held by | Owner |
| --- | --- | --- |
| The kernel never runs runtime code at a preemption, and a preempted executor resumes where it stopped | the kernel enters user mode only by resuming a thread's saved state or, for a worker armed for signals, by Fiasco's vCPU upcall, and arming refuses an executor | [design-scheduler.md](design-scheduler.md#invariants) S1 |
| No wakeup is lost | every trigger of an IRQ object bound to a group, every capacity change and every wake advances the group's epoch under its park lock; a park compares the epoch it read with the current one under the same lock, so a wakeup that lands between a runtime's last look and its park cancels the park | design-scheduler S2 |
| An executor never blocks except to park, or on a umtx word in its own domain's private memory | blocking calls carry an executor attribute in the ABI file, and the generated dispatch refuses every other wait | design-scheduler S3 |
| No group exceeds its parent, whatever a runtime reports | quotas are charged and checked along the whole path; urgency is clamped to the path's ceilings; hints are only inputs to decisions the kernel bounds | design-scheduler S5 |
| A stale capability never names a new object | one lookup checks generation, type and rights; a slot retires before its generation wraps | [design-kernel.md](design-kernel.md#invariants) |
| Rights only shrink | capabilities reach a table only by creation, with at most the rights the creator could hold, or by a copy, a pass or a fork's copy, each of which intersects rights; an export carries at most the rights its owner gave it, and no peer widens one | design-kernel K2, K17; [design-domains.md](design-domains.md#invariants) D4 |
| Every kernel allocation is charged to a budget, and an object dies with its budget | one charging funnel; deleting a budget deletes every object charged to it and every budget carved from it, at once, so no object outlives what paid for it and nothing keeps a budget alive: its record stays, dead and taking no charge, only until calls already under way drop their last reference to what it paid for; every capability to a deleted object then fails the one lookup and every mapping of it faults | [design-kernel.md](design-kernel.md#invariants) K25, K26 |
| The kernel reaches a domain's memory only as UTCB fields or as (object, offset, length) through its own mapping | the kernel never loads or stores through a user virtual address: every argument is a register, a field of the calling thread's UTCB, read through generated accessors that load each field once per decision, or a memory window, a memory capability with an offset and a length, checked against the object's size and reached only through `erx_window_read` and `erx_window_write` over the kernel's own mapping of it; the ABI file's grammar has no pointer type; the one address-keyed call, umtx, translates its address through the caller's page table, an unmapped address being a status and never a fault, refuses with `ERX_EFAULT`, before any load, an address that translates to memory the direct map does not cover, and reads the word through the kernel's own direct map, atomically with the enqueue; the kernel's type for a user address converts to no pointer, so a user address is only a place to map at, to translate or to report a fault at | [design-kernel.md](design-kernel.md#invariants) |
| A mapping never allows more than the capability that made it | each mapping keeps a ceiling fixed from the capability's rights, and `erx_space_protect` moves a mapping's protection only beneath it | [design-kernel.md](design-kernel.md#invariants) |
| Trimming never meets sharing | only private memory is freed by range; it has no capability, and each of its pages is mapped once | [design-kernel.md](design-kernel.md#invariants) |
| Copy-on-write shares only immutable pages | a child's parent can never be written, a child is never a parent, and the child reserves every page it may copy when it is created | [design-kernel.md](design-kernel.md#invariants) K22, K23 |
| No page is executable while another mapping or a confined device can write it, except a JIT object's pages in the one space that made them, and the kernel writes no machine code | the kernel refuses a mapping that is both; code lives in the boot image's slices and in sealed objects, which no CPU or DMA mapping can write; JIT compilers run only in user-mode runtimes, through objects mapped twice in spaces allowed JIT objects, which only the images marked as making them get, and the system domain's image is not one; each JIT object records the space whose thread made it and is mapped into that space alone, so no other space and no device can map it | [design-kernel.md](design-kernel.md#invariants) K8 |
| A pid never names two processes | a pid carries its owner's node, whose creation is the owner's domain id, and domain ids are never reused within a boot | [design-domains.md](design-domains.md#invariants) D1 |
| A domain reaches only what was exported to it, and cannot tell an unexported process from a dead one | the receiver's funnel decides every operation that needs a right from the receiver's own export table alone; an operation without its right gets exactly what one on a process that does not exist gets, from the target's own runtime and in order with what the target sent before; the signals that need no right show the sender nothing | D4, D9 |
| Every frame a runtime accepts passed its funnel | a runtime reads a lane's ring only through the funnel, which copies each frame once into private memory before it looks at it | D3 |
| The system domain's atom table grows only within bounds policy sets | no frame creates an atom in the system domain: the grammar for frames to it has no fun or export tag, and it decodes in safe mode; the only atoms it makes from a request are node names, each bound to the requesting principal on first use within that principal's `names` quota, 64 by default, and sessions and command domains draw theirs from the principal's pool of reusable names ([design-system.md](design-system.md#identifiers)) | D5 |
| A domain speaks only for its own processes | the receiver knows the sending domain by the lane a frame arrived on, and its funnel refuses a frame whose sending pid does not carry that domain's id; no field of a frame is trusted for identity | D6 |
| No process acts on a message from another domain that the owner of its protocol did not admit | the receiving runtime delivers every message from another domain as `{erx_origin, D, Msg}`, `D` the lane's domain, with no flag and no exception; only each protocol's owner takes the envelope off its own shapes (`gen`, `io` and file replies, io-server requests, and calls and casts to a server started to serve other domains), and `sys` takes nothing apart | D18 |
| What a domain can make another hold is bounded by the receiver's own limits, what it can make the system domain hold is a sum reserved at its admission, and no domain can make another wait on it | each lane's ring is charged to the connection's child budget of the outer budget of the domain that reads it, both lanes of a domain's system connection to that domain's, and sized by the reader's policy; the record a receiver is reading grows in its own buffer as its bytes arrive, up to the receiver's `max_frame`, and is never allocated whole on a header's word; queued messages count toward their target's `max_heap_size`, and the funnel keeps each destination process's queued, undecoded bytes under its queue quota, the facet's or, in the system domain, `system_queue` by default, and leaves the next frame for it in the lane once the quota is reached, so flow control backs up to the sender and nothing is allocated past the bound, while a process at quota decodes its queued frames before it waits in a receive; links, monitors and signals held for a peer toward the receiver's `peer_held`; the system domain's queue to a domain stops at the system manifest's `system_queue`, and the domain service reserves the sum of these terms for every admitted domain from the system domain's budget; a sender whose lane is full waits in its own runtime, and a receiver drains at its own pace and spends its own CPU validating what it drains | [design-domains.md](design-domains.md#flow-control), [design-system.md](design-system.md#resource-policy) |
| A client cannot spend a service's CPU or memory beyond the service's admission | a service runs on its own capped grant, and no thread ever runs on another group's time; what it holds per client is bounded by that client's facet process, with `max_heap_size` set and off-heap binaries counted, and that client's lane; decoding is lazy, so an untaken frame costs its bytes in the lane and nothing more; a service's control steps are bounded by construction, and work that grows with a client's input runs in the client's own domain or within the service's grant, scheduled fairly | [design-scheduler.md](design-scheduler.md#service-work), [design-domains.md](design-domains.md#facets), [design-system.md](design-system.md#resource-policy) |
| No capability is ever in flight, and only a space's creator installs capabilities into its table unasked: the system domain into domains, a domain into its sub-spaces | capabilities pass between spaces only at an IPC rendezvous, as typed items installed into slots the receiver reserved, in the operation that delivers the message; `CAPS` on a space comes only with its creation, space capabilities never pass, and its creator's `erx_cap_pass` hands one on with `INSPECT` alone, so a domain holds `CAPS` only on its own space, through `ERX_CAP_SELF`, and on the sub-spaces it created | [design-kernel.md](design-kernel.md#invariants) K17; [design-system.md](design-system.md#invariants) A1, A7 |
| Only a space's creator conveys code, device and structural authority, and `CODE` never leaves the system domain's table | a pass keeps only its type's pass set, which holds no right to execute, make code, reach a device or fill an object others read; no budget, space, thread, group, resource or DMA window passes at all; an IRQ object passes with `TRIGGER`, `INSPECT`, `DUP` and `GIVE` and never with `BIND`, so its receiver can ring it but never take its deliveries; the domain library carves no domain a budget with `CODE`, and itself creates, with the root budget's `CODE`, the code objects and JIT spaces a domain's image allows, so no table but the system domain's ever holds `CODE` | [design-kernel.md](design-kernel.md#invariants) K8, K24 |
| A forked child executes only the code its parent had mapped | the session's copy of a program's sub-space for `fork`, through `erx_space_copy`, which only a sub-space's creator may call, copies capabilities within each type's pass set and decides each mapping by its object's kind, sharing only immutable objects among the executable ones | [design-kernel.md](design-kernel.md#invariants) K8, K24 |
| Deleting an object invalidates every capability to it at once, and memory mapped from it faults from then on | capabilities are flat, as in Fiasco: a copy adds a slot and a close removes one; a deletion, which needs `DESTROY`, first closes the object by invalidating its existence lock, which Fiasco's deletion invalidates only once every slot is empty, an order the kernel's L4 lineage records, so the one lookup fails every capability to it and nothing attaches to it, and waits for the operation that holds that lock; its mappings are then removed, and an access to one faults to the fault gate as `ERX_FAULT_DELETED`; the object is freed only after an RCU grace period | [design-kernel.md](design-kernel.md#invariants) K25, K26 |
| A server never maps memory a client can delete or end, and no party to a connection can make the other fault | The rule: memory crosses a domain boundary only through objects the system domain created, holds the delete right to and charges to a budget that outlives every party that maps it. No domain holds an IPC gate of another domain: the domain library, the one installer into a domain's table (A1), installs a domain's connections and resources, maps the sealing page into the vault's domain alone and never installs another domain's gate, so what a domain and its sub-spaces pass each other at a rendezvous stays inside its own budget tree. A server or driver otherwise maps only memory it created, and reaches memory a client owns only through `erx_mem_copy`, which copies between two memory objects and fails with `ERX_ESTALE` instead of faulting. The system domain and the pipe server give no client `DESTROY` on memory another party maps. Ending a domain destroys its own budget, which pays for nothing another domain maps. Each lane of a connection is charged to a child budget, one per connection, of its reader's outer budget, both lanes of a domain's system connection to that domain's; no other memory of one domain is mapped into another, since the domain library maps none but a connection's; the system domain destroys a child only once both parties have let go, never on a timer while a party lives, so a survivor that never lets go keeps alive that one connection's child budget and the outer budget it was carved from, with its crash area, but no other connection's lanes: the memory it pins is bounded by its own `connections` quota plus the dead domain's outer budget. Only the crash area is charged to the outer budget directly, and the system domain destroys the outer budget once no child remains and the crash record is read. The domain holds no capability to its outer budget, and the system domain spends none of its own budget on a domain's behalf; the sealing page and an unconfined device's memory, which live for the whole boot, are the machine's | [design-kernel.md](design-kernel.md#closing-and-deleting); [design-system.md](design-system.md#authority); [design-domains.md](design-domains.md#connections) |
| Nothing outlives its creator: a domain ends with the system domain, a program with the session that started it, its children survive its `exec`, and a sub-space never outlives its creator | every space has a parent fixed at its creation and stops when its parent stops; every domain's space is a child of the system domain's; each program has a threadless anchor whose parent is its starter's anchor, or the session's space, and whose children are the program's images and its children's anchors, so `exec`, which replaces only the image, stops no child; a sub-space's parent is its creator's space or one of its sub-spaces | [design-kernel.md](design-kernel.md#creating-spaces); [design-system.md](design-system.md#the-root-task); [design-programs.md](design-programs.md#a-programs-end) |
| No grant writes and runs a file together, and only an `rx` grant runs one | a grant's rights are one of `ro`, `rw` and `rx`, and a server refuses an `exec` open on any other grant | [design-files.md](design-files.md#invariants) F6 |
| A file's bytes mapped shared live in one place per session | the session's one mapper process for a mapped file holds one memory object for it, maps that object into every image of the session that maps the file, fills it with ordinary reads through the file protocol, copied in from a staging object with `erx_mem_copy` so that no fill marks a page stored, and writes back with ordinary writes only the pages `erx_mem_dirty` reports stored, at `msync`, at every `close` of an open that maps it and at the file's last `close`; another session that maps the file holds its own copy, and each sees the other's stores after write-back, as two machines sharing a network file system do | [design-files.md](design-files.md#invariants) F7 |
| An update always leaves a bootable committed system | slots are written only under `normal(C)`; the record names only the slot first installed or one that passed a healthy trial; only a complete spare is ever tried, checked against its update manifest, which the slot writer writes last, into the spare's manifest window; a torn record is the one case that needs an installation | [design-storage.md](design-storage.md#system-updates) U1 to U5 |
| A path never reaches a file server the domain does not hold, nor anything above its grant's root | a namespace entry stores only a grant's pid, a request is a frame the server's funnel admits only within the server's exports to the sender, and the server fixes every grant's root and never follows a link during a walk; a program holds no grant's pid at all, since its handler relays its requests | [design-files.md](design-files.md#invariants) F1, F2 |
| A pipe's reader sees the end of the stream once every writer has gone and every byte written has been read | the session alone installs every pipe end into a program's sub-space and records its holder, so it knows every holder by construction; its own records say which ends remain, and it keeps every ring, whose memory it never deletes, until a reader has drained it, so a gone writer's bytes stay readable | [design-pipes.md](design-pipes.md#invariants) PI1, PI2 |
| A command acts only through the capabilities it was handed, and one with less than its session's runs in a space of its own | an Erlang command reaches services only through the facets in its context; a narrowed Erlang command, and every Erlang command a program starts, runs in a command domain built from exactly what its starter named; a program runs in a sub-space holding exactly what its starter handed it, and reaches nothing but its channel and the memory its session mapped | [design-shell.md](design-shell.md#invariants) SH1, [design-programs.md](design-programs.md#invariants) P2 |
| A program's bytes reach a terminal as its tty's flags leave them | one owner per tty, one pure output function, and nothing after it reads the bytes | [design-live.md](design-live.md#invariants) V1 |
| Text labelled with its source is displayed only through the line escape | each display builds its line with the escape, from one generated table | [design-live.md](design-live.md#invariants) V9 |
| Only the system shell types expressions into the system domain, and only a login at a secure console line opens it | the console starts a system shell only under the system-shell facet, which it grants to a login at a line the manifest marks `secure`, holds itself and ends with that login; no session ever holds it | [design-live.md](design-live.md#invariants) V6 |
| The kernel, `liberx`, the runtimes and Erlang agree on the ABI, and code agrees with the hardware's registers | all are generated from `abi/erx_abi.txt`, the CMSIS-SVD files and the system-register specification, and the build generates every output into `build/gen/`, so no checked-in copy can be stale | [One source](#one-source-for-the-abi-and-the-hardware) |
| No kernel stack overflows | every thread's kernel stack is proven, for every kernel configuration that is built, to hold its deepest kernel path with the deepest interrupt path on top, and every other stack its entry's; interrupt handlers are checked never to nest; kernel code recurses only through `musttail` calls; stacks have guard pages | [Bounded stacks](#bounded-stacks) |

## Decisions

Decisions that constrain more than one subsystem:

| Decision | Rationale | Specified in |
| --- | --- | --- |
| **Hierarchical scheduling with grants is the normal execution model.** The kernel schedules threads within groups' grants; runtimes schedule lightweight processes on their executors. | The user's decision. ERTS's scheduler switches processes without entering the kernel and is proven; the kernel needs one authority over CPU time for every thread, native or runtime. | [design-scheduler.md](design-scheduler.md) |
| **The six rules of the two-level contract.** Executors are ordinary preemptible threads; preemption never runs runtime code; wakeups and capacity changes are queued events, taken at safe points; executors never block except to park, a umtx wait in the domain's own private memory counting as inside the domain; budgets are enforced whatever the hints say; there is no donation: every thread is charged to its own group. | Each rule removes a failure that ended an earlier two-level system: re-entrancy, lost or reordered events, executors lost to blocking, trust in user-reported state, and inheritance of another's time, which puts a scheduling dependency between domains and a payer to derive and audit at every call ([research](research-hierarchical-scheduling.md#negative-evidence)). | [design-scheduler.md](design-scheduler.md#context) |
| **erXos's own C17 kernel on Fiasco's design; a near-stock Fiasco as the stopgap for Phase 1.** The kernel interface is erXos's; `liberx`'s Fiasco backend implements, above Fiasco and not inside it, the part of the interface that Phase 1's system uses (the system domain's runtime and the live machine, domains and their connections, the command shell with its programs, immutable code and one data store, and in Phase 1b the web and display domains, drivers in their own domains and networking on QEMU), as its call table lists; erXos's kernel boots the same system and replaces the stopgap, gated on the conformance suite and the system's tests, before the security closure milestone, and every mechanism beyond that system lands on erXos's kernel alone. | A working system first, on proven code, without letting Fiasco's model leak above the interface; a stopgap held to what Phase 1's system uses keeps Fiasco near-stock and builds no mechanism twice; a kernel of its own, reshaped for erXos (budgets, groups, generations, memory objects), once the architecture has settled. [What erXos's kernel adds, in brief](design-kernel.md#what-erxoss-kernel-adds-in-brief) summarises how it differs from Fiasco and what each difference buys. | [design-kernel.md](design-kernel.md#the-current-implementation-the-modified-fiasco), [plan.md](plan.md) |
| **The kernel keeps Fiasco's model wherever erXos needs nothing else.** [Kernel](#kernel) lists what it keeps, from a kernel stack per thread with helping locks to the vCPU interface for signals; every departure is in the kernel's L4 lineage ledger, with its reason and what Fiasco's way would lose. | The user's standing principle, to minimise needless changes from the L4 model; Fiasco's design and know-how come with its model. | [design-kernel.md](design-kernel.md#l4-lineage) |
| **The Fiasco fork is frozen and owned.** It enters the tree once, with its notices and an origin file; upstream is not tracked; new C++ is allowed only for kernel objects and hooks that integrate with Fiasco, with the policy and state machines behind them in C17 shared with erXos's kernel. | The user's decisions; the C17 cores move to erXos's kernel unchanged. | [design-kernel.md](design-kernel.md#the-current-implementation-the-modified-fiasco) |
| **Every runtime in user mode.** The system domain's ERTS too. | A runtime's fault ends a domain, not the machine; the kernel writes no machine code and carries no runtime. | [design-runtime.md](design-runtime.md) |
| **The system domain runs the interpreter.** ERTS comes as two runtime images, the interpreter and BeamAsm; the system domain's image is the interpreter, without BeamAsm, asmjit or any C++, and the domain library gives it no JIT object. Ordinary domains run the BeamAsm image by default, storage and network included. The development manifest, whose image the website also serves, runs storage and network on the interpreter, and the net_device suite's exchange cell runs the network domain on BeamAsm for its throughput figure. | No JIT object, no view of memory that is writable before it is executable and no C++ exists in the trusted base; the system domain does bounded control only, so the interpreter's slowdown costs it little, while the domains that do the machine's heavy work keep the JIT. BeamAsm compiles every module it loads, so a development boot that starts several runtimes on one CPU reaches `/data` and the prompt sooner on the interpreter ([todo-performance.md](todo-performance.md)). | [design-runtime.md](design-runtime.md#beamasm), [design-system.md](design-system.md#the-root-task) |
| **The kernel never dereferences a user address.** The kernel never loads or stores through a user virtual address. Each argument is a register, a field of the calling thread's UTCB, which the kernel maps and reads through generated accessors that load each field once, or a memory window, a memory capability with an offset and a length, which the kernel reaches only through `erx_window_read` and `erx_window_write` over its own mapping of the object, and the ABI file's grammar has no pointer type; a request larger than the UTCB travels in a memory window the caller names, and every result returns in registers or the UTCB. The one address-keyed call, umtx, translates its address through the caller's page table, so an unmapped address is a status and never a fault, refuses with `ERX_EFAULT`, before any load, an address that translates to memory the direct map does not cover, such as device registers, the boot image or the crash region, and reads the word through the kernel's own direct map, atomically with the enqueue, so the futex property holds with no copy. | A request cannot change between its check and its use, since the kernel reads each field once from memory it maps itself, and a domain cannot aim the kernel at memory it should not touch, since the kernel never follows an address a domain supplied. This holds by construction rather than by a copy discipline: the kernel has no functions that copy from or to user memory, no address validation, no window in which it may touch user memory and no table of fixups for faults taken in one, and so no architecture feature that guards such a window. Fiasco's messages already travel in the UTCB, and every call that differs from Fiasco's for this rule is in the kernel's L4 lineage ([design-kernel.md](design-kernel.md#l4-lineage)). | [design-kernel.md](design-kernel.md#invariants), [design-runtime.md](design-runtime.md#liberx) |
| **`liberx` is the only issuer of kernel calls.** Its backends are erXos's kernel, the stopgap Fiasco and a hosted implementation on macOS. | Seams, not rewrites: nothing above `liberx` changes when the kernel does. | [design-runtime.md](design-runtime.md#liberx) |
| **Every domain is a node, and a pid carries its owner domain.** Each domain is an Erlang node named by its identifier at the machine's host name, such as `web@erxos`, `alice@erxos` or `system@erxos`, with its domain id as its node's creation; domain ids start at 4, the system domain's being 4, since stock `erlang:setnode/2` raises a creation below 4 to 4, and are never reused within a boot. A connection between two domains is a distribution connection between two nodes in stock ERTS's sense, one distribution entry per peer, keyed by the peer's name with the peer's creation as stock keys them, so `node()`, `nodes()` and `monitor_node` keep their stock semantics, and `rpc:call`, `rpc:cast` and `erpc` work through `spawn_request` where the caller may spawn. For a node at this machine's host name, `net_adm:ping/1` answers `pong` when the node is `node()` or in `nodes()` and `pang` otherwise, and never calls `erlang:disconnect_node/1`, since a connection exists only by introduction; toward another machine's node it behaves as stock. `erlang:disconnect_node/1` of the system domain's node keeps its meaning: the system connection ends, and with it the domain. Registered-name sends are outside the frame grammar, so `rpc:block_call`, `rpc:abcast`, `rpc:sbcast`, `rpc:server_call` and `rpc:multi_server_call`, which send to registered names, are documented differences with tests, and `global` and `pg` see only the local node: they do not span domains by design, and a release that sets `connect_all` to true fails the build. A pid prints as `<D.N.S>` and a port as `#Port<D.N>` in every domain, its own domain's included. | Uniqueness, locality and stale-pid safety by construction, with no registry, and ERTS's own node identity does the work with no change to its node table: a pid names its owner's node, whose creation is a domain id that is never reused. The text is the user's decision: a pid reads the same wherever it is printed and names its owner. Stock OTP prints the channel number of a local pid as 0, through `internal_channel_no`, and of a remote one as its distribution entry's, through `dist_entry_channel_no`, which a reconnect overwrites. erXos's runtime changes the channel-number macros for pids, ports and references (`internal_channel_no`, `external_channel_no` and their port and reference variants) to print the node's creation, this node's for a local one and its own node's for a remote one, so a pid of an ended domain keeps printing that domain's id; the parsing BIFs, `list_to_pid` and its kin, resolve `D` to this node or to the connected node whose creation is `D`, and fail with `badarg` otherwise. The channel-number macros and the parsing BIFs are the one documented difference, with a test. | [design-domains.md](design-domains.md#domain-ids-pids-and-references) |
| **Every cross-domain signal travels on a connection, and the receiver's funnel checks it.** A connection is two lanes, one per direction; a lane is a ring the producer alone writes, a reader page the consumer alone writes, and an IRQ object as doorbell, the one layout of every lane, a pipe's and a program's channel included. The system domain makes a connection when it introduces two domains, at a domain's creation for its connection to the system domain itself and later by a facet grant, a spawn into another domain or an explicit introduction by a caller whose domain holds `introduce`, a distinct export right that only the owner's own export writes, on both domain pids; each lane is charged to a child budget, one per connection, of the outer budget of the domain that reads it, both lanes of a domain's system connection to that domain's, sized by the reader's policy, and the system domain alone holds the delete right to a connection's objects. Who may signal a domain's processes is an export table that the receiving runtime owns and alone writes; the funnel that checks every frame against it is one C17 library in `liberx`, linked by every runtime. A malformed frame ends the connection from the receiver's side, and the peer sees `noconnection` across it; that is the whole protocol-error rule. | The user's decision. Identity holds by construction, since the lane names the sender and no field is trusted for it; a frame is copied once and validated by the party that bears its consequences, on its own grant; flow control is the ring, so a flooder fills its own lane and blocks itself, as stock distribution's busy connection does; and the trusted base for messaging is the kernel and each domain's own runtime, with no third party whose deadline becomes a machine-wide net split. The cost is two lanes per introduced pair instead of ring memory per domain, and a parser defect that ends the receiving runtime instead of a third party ([Alternatives considered](#alternatives-considered)). | [design-domains.md](design-domains.md#connections), [design-domains.md](design-domains.md#the-funnel) |
| **Payload identity and operation authority are separate.** Pids and references of other domains travel unchanged in a payload. A process's own pid or alias, placed in a frame by its owner, exports it to the receiving domain with `send` alone, which is stock Erlang's semantics of handing out a name; a spawn into a domain exports the spawned pid toward the spawner; an explicit export function does the same on request; nothing else writes an export. A live facet's policy scope produces operation-bound handles, which generated privileged service helpers accept, never bare request names. | The user's decision: preserving data identity avoids map-key corruption, and one admission boundary prevents confused deputies without rewriting arbitrary terms or trusting every callback to recheck ambient rights. | [design-domains.md](design-domains.md#exports), [design-domains.md](design-domains.md#authority) |
| **Shared services run on their own grant and do bounded control.** No thread ever runs on another group's time. A service's grant is capped and sized by policy for the domains it serves; it admits per client through that client's facet process and lane; its control steps are bounded by construction, with generated decoders under schema bounds and no loop over client-sized data outside the decoder; work that grows with a client's input runs in the client's own domain, validated completely by the service, or in the service's domain within its grant, where the service schedules its clients fairly as Erlang schedules its processes. Per-client CPU attribution is an inspector statistic the service's processes report, never an enforcement mechanism. | The user's decision. A capped grant per service needs no payer, loan, floor or account; what one client can make a service spend is bounded by that client's facet and lane, and what the service can spend in all by its grant. The cost is that when a service's quota is hit, every client of that service slows together, as Genode's components do under their CPU quotas and memory per session. | [design-scheduler.md](design-scheduler.md#service-work), [design-system.md](design-system.md#resource-policy), [design-domains.md](design-domains.md#facets) |
| **Finishing a stopped call runs outside every quota, at a finishing level above every urgency within a fixed share of each CPU, and is counted on the stopped thread's own groups as finishing time; reclaiming a stopped space or destroying a budget is charged to the caller as any call is.** On erXos's kernel a killed thread finishes on its own CPU within that CPU's finishing share, 4 of every 8 ticks; the stopgap runs it at the same fixed level with no share, a stream of kills there holding a CPU's user threads back for as long as it lasts, a stopgap residual of development builds, which run trusted code only; no grant throttles or places it; its time is added to a separate `finishing_ns` counter of every group on its own path, never to their usage, so the inspector shows a stopped domain's finishing time apart from its ordinary time and attributes it to the stopped domain, not to whoever stopped it. A kill names no group and takes no reference. | The user's decision. No grant, the stopped party's or the stopper's, can hold an exit record back, and there is no reservation, sponsor or maintenance queue to size and audit: the share, a few words per CPU, bounds what finishing takes from a CPU's user threads, and the stopped space's budgets bound the work in all. Counting the time on the thread's own path needs no second path per thread: the groups it charges are the ones it already holds until its last switch. The cost: a stopper cannot cap with its own grant how much CPU the finishing of what it stops takes, and the inspector does not name the stopper; the share caps the time per CPU instead. | [design-kernel.md](design-kernel.md#execution-model-and-locking), [design-scheduler.md](design-scheduler.md#kernel-calls) |
| **Budgets are space banks.** Deleting a budget deletes, at once, every object charged to it and every budget carved from it, as EROS's space banks do; an object does not keep its budget alive, and no charge outlives the budget it was made from. Ending a domain is destroying its budget, after which every capability to its objects fails the one lookup and every mapping of them faults. What must outlive a domain is charged to a budget that outlives it: a file server's objects to the server, a session's programs to the session, and whatever another domain maps to the domain's outer budget, a connection's lanes through a child budget per connection, which the system domain destroys once both parties have let go, and the outer budget once no child remains and the crash record is read (decided provisionally, [Risks and open questions](#risks-and-open-questions)). Within a session, a program's budget holds only what the program alone maps; its channel lanes, data areas and pipe rings are charged to the session's own budget, deleted after the program's budget is destroyed. Device DMA memory needs no budget rule of its own: an unconfined device's memory is the system domain's for the whole boot and is never freed, so no DMA memory quarantine exists, and a confined device's memory is charged to its holder's own budget and freed only after the kernel unbinds its window. | The user's decision. Ending a domain is one destruction with nothing left to drain: no state in which a dead domain's objects linger, no rule for who keeps them alive and no recovery of a dead budget's objects. The system domain's objects for a domain are charged to that domain's budget and die with it, which is the intent; what one domain gives another dies with the giver, so a holder that must keep something charges it to itself. | [design-kernel.md](design-kernel.md#budgets), [design-kernel.md](design-kernel.md#closing-and-deleting), [design-system.md](design-system.md#ending-a-domain) |
| **A budget has a guarantee and a cap, and a program draws on its session's pool.** Every budget has a guarantee, carved from its parent and never taken by another budget, and a cap up to which a charge borrows the room its ancestors have promised to no one, counted at each of them by one chain in the kernel; its carver resizes both while it lives. A budget is carved as a **wall**, whose cap is fixed equal to its guarantee, or **elastic**. A domain's own and outer budgets are walls, so every charge of a domain's is admitted or refused at its own budget, none is counted against another domain's, and against its principal's room only what the principal's own shrink of the domain moved there. A session carves a pool for its programs, a wall, and each program's budget from it, elastic, with a floor as its guarantee and the pool as its cap unless the starter asks for less, so a program is refused only when the pool is full, as a QNX process is at the system's pool within its `RLIMIT_AS`. Reserving address space costs nothing; a page is charged when a commit, or a protect that gives a reservation access, promises it, never at a fault. | The user's decision, so that ordinary POSIX programs behave as on QNX: a program is not refused while its session has memory free, and the memory a domain is given depends on nothing outside it but the kernel. The kernel's chain does in one lock what resizing by the session at every refusal would do in round trips inside `malloc`. | [design-kernel.md](design-kernel.md#budgets), [design-kernel.md](design-kernel.md#virtual-memory), [design-system.md](design-system.md#resource-policy), [design-programs.md](design-programs.md#the-posix-lite-personality) |
| **The system domain is the root task; policy and mechanism for domains live in one place, Erlang policy over a C17 domain library.** The kernel starts one task; `liberx`'s root-task entry receives the root capabilities, builds the system domain's own memory, threads and group, and starts ERTS, which boots the system release. The domain library, in `liberx`'s system layer and called through NIFs, plans a domain whole before it applies anything and installs into it only capabilities from the system domain's own table. Every domain's space is a child of the system domain's, so the kernel's space tree ends every domain with it; a fault of the system domain, its halt outside an ordered shutdown, or a missed watchdog resets the machine after a crash record, and there is no recovery protocol because nothing is left to reconcile. A domain that the system domain lets hold `SPACES` creates sub-spaces of its own, as any L4 task holding a factory creates tasks, charged to its budget, faulting to a gate it names, and stopping and dying with it. | The user's decision. A separate root task buys one thing, that configured services ride through a fault of the system runtime, and costs two system-domain instances overlapping in one budget, identity and re-grant rules in every configured registry, device reconciliation, and a second trusted program with its own protocol, ring and fuzz target; erXos takes the reset, as OTP's `heart` does, and keeps the domain library behind one C interface, so a separate root task remains a change behind that seam ([Alternatives considered](#alternatives-considered)). | [design-system.md](design-system.md#the-root-task), [design-system.md](design-system.md#the-domain-library), [design-kernel.md](design-kernel.md#the-root-task), [design-kernel.md](design-kernel.md#the-watchdog) |
| **Capabilities pass at a rendezvous and are flat, as in Fiasco.** Spaces that share an IPC gate pass capabilities as typed items of an IPC, within each type's pass set, into slots the receiver reserved, and no queue holds one. Within a domain's tree, a session and its programs or a domain and its sub-spaces, that is the ordinary way to hand a capability on. Between domains no capability passes: the domain library, the one installer into a domain's table, installs connections and resources and never a gate of another domain, and no system manifest introduces a shared gate between two domains, so memory crosses a domain boundary only through objects the system domain created and charged to outer budgets. A copy is a slot of its own and a close removes one slot; deleting an object, with its delete right, invalidates every capability to it at once and unmaps it everywhere, and what one holder must lose alone it gets as an object of its own, such as a lane per connection. Objects die as in Fiasco, in two phases with an RCU grace period between. | The user's decisions: direct passing between processes, and Fiasco's flat object space and object lifetime. Nothing in flight means no collector for capabilities in queues; flat capabilities keep Fiasco's model and let the stopgap use Fiasco's object space as it is ([design-kernel.md](design-kernel.md#l4-lineage)). | [design-kernel.md](design-kernel.md#passing-capabilities), [design-kernel.md](design-kernel.md#closing-and-deleting) |
| **Deleted memory faults, and no server maps what a client can delete or end.** An access to memory whose object was deleted, by its delete right or with the budget that paid for it, faults like any other access the kernel cannot resolve: a program ends with `SIGBUS`, an Erlang domain ends and its supervisor restarts it. A server or driver maps only memory it created, or memory that the system domain created for the connection between the domains or the driver connection and charged to an outer budget, and copies memory a client owns with calls that fail with an error. | The user's decision: an access to memory that is gone is a bug or an attack, and it must show where it happens rather than as silent wrong data. The rule for servers keeps deletion, and a client's end, from becoming a way to crash a server, by construction rather than by hiding the fault. | [design-kernel.md](design-kernel.md#closing-and-deleting) |
| **A session serves its programs' shared mappings.** `MAP_SHARED` of a file is served by the program's session, not by the file's server: the session holds one mapper process and one memory object per mapped file, fills the object from the server with ordinary reads through the file protocol, copied in from a staging object with `erx_mem_copy` so that no fill marks a page stored, maps it into each program's image that maps the file, and writes back with ordinary writes only the pages the kernel reports stored (`erx_mem_dirty`), at `msync`, at every `close` of an open that maps it and at the file's last `close`. A fault on the object is the session's own and the kernel resolves it from the object; no fault waits on another domain. A shared mapping is coherent among the programs of one session; two sessions that map one file each hold their own copy and see each other's stores after write-back, as two machines sharing a network file system do, and plain reads and writes from elsewhere see the file once it is written back. That is a documented difference from POSIX with a test. | The user's decision. Coherence within a session holds by construction, since its programs share the one object (F7), and every fault resolves from its object or ends the thread, so no fault waits on another domain. Coherence across sessions is what this gives up: 9P2000.L, the standard the file protocol is, has no operation that could carry it ([Alternatives considered](#alternatives-considered)). | [design-files.md](design-files.md#shared-mappings), [design-programs.md](design-programs.md#shared-libraries-and-mappings-of-files), [design-kernel.md](design-kernel.md#copy-on-write-children-and-copies-of-spaces) |
| **Signals arrive through Fiasco's vCPU interface.** A worker armed with a vCPU state area takes its signal IRQ object's events as upcalls and returns with an atomic resume; executors are never armed, faults never become upcalls, and a call's reply wait is never cut short. A signal from outside a program is a report on the program's channel, and the program's own event executor raises it and triggers the signal IRQ object of the thread that takes it; the session holds no capability to the signal IRQ object of any of the program's threads, only to the doorbells it made itself for the program's channel and pipe ends. `SIGKILL` is the session stopping the program's anchor, and `SIGSTOP` and `SIGCONT` its pausing and resuming the program's image, none of which needs the program's cooperation; a resume is followed by the `SIGCONT` report whether the program catches, ignores or blocks it, since the session never sees the program's dispositions. | The user's decision to use Fiasco's interface rather than an erXos mechanism. Preemption still never runs runtime code, every fault still reaches the space's fault gate, and a request already sent is never abandoned for a signal. A signal on the channel stays in order with the reports it relates to, a child's exit before its `SIGCHLD`, and nothing of the session's has to follow a program's threads across `fork` and `exec`. | [design-kernel.md](design-kernel.md#vcpu-upcalls), [design-programs.md](design-programs.md#signals-in-liberx) |
| **Pipes live in user space, at home in each session.** A pipe is a single-producer ring in memory that the session's pipe server, in Erlang, creates and maps into the sub-spaces of both ends; the session alone installs every end and makes every doorbell, as it makes the ends, so it knows every holder by construction and the end of the stream follows from its own records; a pipe with many writers blocks a writer, never a spawn; a pipe between sessions goes through the sessions' handlers over their connection. | The user's decision to keep pipes out of the kernel. End of stream and broken pipe follow from who holds the ends, which the one installer of ends knows; the data path makes no kernel call while the other side is awake; and every pipe's structure is Erlang, inspected and supervised like any service. | [design-pipes.md](design-pipes.md), [design-pipes.md](design-pipes.md#making-a-pipe) |
| **ERTS is a parts bin; the design comes first.** OTP 29.1.2 and musl enter the tree as erXos's code and are taken apart and recombined; for each job one mechanism is kept or redone. | Simplicity and elegance are the measure; tracking upstream would forbid the recombination. | [design-runtime.md](design-runtime.md#the-inventory) |
| **The Erlang-visible behaviour of what erXos keeps is checked against stock OTP 29.1.2 in an offline Linux container on the development host; native host OTP remains the bootstrap compiler and a separate performance baseline.** | The oracle is what makes heavy modification safe; container-owned process and network namespaces let stock suites create local peers without reaching operator services or the external network. | [Testing and the oracle](#testing-and-the-oracle), [host oracle design](design-host-oracle.md) |
| **The plain configuration is the baseline; cooperation earns its place.** Each cooperation feature (published urgency, deferred preemption, status words, wake placement) is a group flag with an off switch, and `erx.sched` caps them machine-wide. | Two-level systems failed by adding coordination that was not needed; each feature is measured against executors as ordinary threads. | [design-scheduler.md](design-scheduler.md#performance) |
| **Functional core, effects at the edge.** Kernel, `liberx`, driver and runtime decisions are pure functions; multi-step operations are planned and validated whole before one point of no return. | Sequencing bugs come from callers that string helpers together; pure decisions are tested exhaustively on the host. | [Correct by construction in code](#functional-core-effects-at-the-edge) |
| **TLA+/TLC checks protocol models; C17 and Erlang implement the decisions.** Independent abstract and mechanism models check ownership, authority, lifetime and progress under explicit bounds and assumptions. Each invariant maps to implementation checks, with good configurations and targeted broken variants. | The user selects TLA+/TLC. Models expose protocol errors before implementation, while host exploration and concrete tests check whether the implementation follows the model; generating both sides from one rule would leave that rule unchecked. | [design-verification.md](design-verification.md) |
| **The ABI and the hardware each have one source.** `abi/erx_abi.txt` for calls, rights, status codes, limits and fixed layouts (rings, reader pages, frames, boot information, crash headers included), with each architecture's call registers and hardware layouts in `abi/arch/<arch>.txt`; CMSIS-SVD files for memory-mapped registers; per architecture, one checked-in system-register specification derived from the architecture's machine-readable one. | Nothing is copied by hand, so nothing drifts. | [One source](#one-source-for-the-abi-and-the-hardware) |
| **Shared interface facts generate every representation.** Ruby generators derive service clients and admission/dispatch, inspection types and projections, contextual error mappings, log/trace bindings, reference tables and parser test scaffolding from their declarations; the checked manifest and release metadata produce startup and command catalogs. | One fact has one source across languages and tools. Handwritten pure cores keep policy and lifetimes explicit, and independent models and fixtures check generated implementations rather than sharing their expected answers. | [design-generation.md](design-generation.md) |
| **Chokepoints are build checks; kernel stacks are proven.** | A rule of the form "only X may do Y" holds only while it is checked; a kernel stack overflow is a silent corruption unless it is impossible or caught. | [Chokepoint checks](#chokepoint-checks), [Bounded stacks](#bounded-stacks) |
| **Development builds run trusted code only** until the security closure milestone, which runs on erXos's kernel. Their banner says `development build: trusted code only`. | The stopgap is never hardened; the closure needs the kernel whose construction rules bind all of it. | [plan.md](plan.md) |
| **Languages.** New code is C17, Erlang and Ruby, plus each architecture's assembly where C cannot express the operation, and `make`, minimal POSIX shell and linker scripts for build glue. No Rust and no new C++, except kernel objects and scheduler hooks in the stopgap Fiasco that integrate with its C++. Inherited code keeps its languages: BeamAsm and asmjit (C++), OTP's Perl generators and autoconf, Fiasco's C++, its preprocessor and `mk`. | A small set of languages the project can own; inherited code is not rewritten for its language alone. | here |
| **Inherited build machinery stays behind one seam.** OTP's `configure` and makefiles and Fiasco's `mk` are invoked by erXos's top-level build through one entry point each. | Keep what works; keep it replaceable. | [Build and toolchain](#build-and-toolchain) |
| **Third-party code that erXos changes enters the tree as erXos's code; code used unchanged is fetched and built out of tree.** | Forked code must be readable and changeable in place; unchanged code stays replaceable. | [Dependencies](#dependencies) |
| **Formats are erXos's from day one.** The kernel interface, the boot image, image manifests, the system manifest, rings and frames, the host-link frame, the inspection schema and the escape rules are versioned and owned by erXos; no stopgap's data model or ABI reaches Erlang code or users. Where a standard fits, erXos implements the standard itself rather than a variant of it: the file protocol is 9P2000.L. | Seams, not rewrites; a standard protocol at the machine's edges lets the host's and other systems' clients and servers meet erXos's without an adapter. | [Formats](#formats) |
| **No backward compatibility in development.** Until a release promises compatibility, a change to a format, protocol, interface or stored state that erXos defines replaces the old form outright: no conversion, migration, shim or reader for old versions; an installation re-creates what an earlier build wrote, and state that does not parse is refused with a diagnostic. Version fields stay, so a mismatch fails loudly; the update path's security version and the behaviour of stock OTP, musl and POSIX are not compatibility and stay. | The user's decision: no design or implementation time goes to transitions while nothing is released. | [Compatibility](#compatibility) |
| **One machine configuration under both accelerators.** The harness pins QEMU `virt`'s machine type, interrupt controller, MSI frame and CPU model, so TCG and HVF run the same interrupt path. | A test that passes under only one accelerator is a bug until explained, and one configuration, within what HVF's in-kernel interrupt controller offers, keeps the two comparable ([research](research-kernel-bases.md#qemu-virt-under-tcg-and-hvf), [research](research-hierarchical-scheduling.md#fiasco-under-hvf)). | [design-platforms.md](design-platforms.md#qemu-virt) |
| **`os:type()` is `{unix, erxos}`.** | OTP's path handling keys on the OS family; erXos paths are POSIX. | [design-runtime.md](design-runtime.md#erlang-visible-behaviour) |
| **QEMU `virt` first, then the Raspberry Pi 4 Model B, then the Raspberry Pi 5.** The platform layer drives each platform's interrupt controller; every platform starts CPUs and ends the machine through the same firmware interface, which the Pi 4's boot partition supplies ([design-platforms.md](design-platforms.md#firmware)). | The user chose the Raspberry Pi, either model. The Pi 4 comes first because QEMU's `raspi4b` model helps its bring-up and its SD and Ethernet controllers sit on the SoC, where the Pi 5's Ethernet sits behind an I/O controller on PCIe and interrupts through Broadcom's MSI frame; Fiasco's support for both boards is the reference ([research](research-boards-storage.md#fiascos-raspberry-pi-support)). | [Portability](#portability) |
| **System code is Erlang, drivers included; C is for per-byte primitives and device shims.** What erXos writes for the running system, the system services, the network stack, the file systems, the slot writer and the drivers included, is Erlang unless that would cost too much performance; stopgaps may be native. The kernel, `liberx`, the per-byte primitives (hashes, checksums, compression, bulk copies, the network's copies that cut runs of TCP segments into frames, and the merge of received segments) and the device shim, the device NIF's thin C under every driver, which parses nothing a device wrote, are C. A driver is an Erlang process under a supervisor over the device NIF; every other piece of native driver code is a native shim, a row in the driver table, a stopgap's included, and a native driver exists only where gate G9's measurement shows that an Erlang driver misses the device's timing or costs more than a stated fraction of its throughput, its row carrying the measurement. | The user's decision: "I definitely want most drivers in erlang with exceptions only when needed or perhaps with a small C shim for perf-critical parts." Every connection, open file and device is a process that can be inspected, traced, supervised and upgraded live, and a parsing bug in the network stack, a file system or a driver's view of its device crashes a supervised process instead of corrupting memory. Erlang does the work done once per packet, block, file or descriptor, and C the work done once per byte. Where a pass C makes over a frame's bytes anyway also needs the frame's header fields, C writes the values Erlang chose or groups frames by a fixed rule within that pass, and decides nothing of the protocol. The owner decided this for the network's fast path, ahead of gate GK3: C does per-frame work inside the copy and the merge, cutting runs and grouping segments, and no TCP decision moves to C, since on the FreeBSD test host one connection's per-segment Erlang step, not its bytes, held the stack to about a seventh of lwIP's throughput ([design-network-fastpath.md](design-network-fastpath.md#the-problem)). A prototype of the packet path is measured on QEMU as a baseline and again on erXos's kernel, where TCP's fast path is decided ([plan.md](plan.md#decision-gates), gates GN-QEMU and GK3), and G9 measures the drivers. | [Drivers and DMA](#drivers-and-dma), [Storage and networking](#storage-and-networking), [design-system.md](design-system.md#the-driver-table), [design-runtime.md](design-runtime.md#per-byte-primitives), [design-network-fastpath.md](design-network-fastpath.md) |
| **Erlang reaches the kernel's entropy generator through one call, open to every domain.** `erx_bytes:entropy/1` returns up to 256 bytes from one `erx_entropy_read` or raises, and never substitutes bytes from another source. Any process in any domain may call it, and Erlang code that needs unpredictable values (keys, secrets, identifiers an attacker must not guess) draws them from it, directly or through a generator it keys, or, in a domain that loads OTP's `crypto`, from `crypto:strong_rand_bytes/1`, whose OpenSSL generator is seeded from `erx_entropy_read`; never from `rand`. | The kernel already lets any thread read its generator, as `getrandom(2)` lets any UNIX process, and ERTS and musl read it for themselves, so an Erlang entry adds no authority: the generator replaces its key after every request, so one caller's bytes reveal nothing of another's or of earlier output, and on erXos's kernel a read costs the caller's own time and a short hold of the generator's lock (on the stopgap it is a request to the root's generator service, a residual of the stopgap). One entry with one failure contract leaves no user to invent a fallback, and a failed read raises, so no caller continues with a value it never got. `rand` is not cryptographic and seeds itself from the clock. How good the generator's seed is belongs to the machine, reported in the boot banner and refused at boot by a release build when weak, not to a call. | [design-runtime.md](design-runtime.md#per-byte-primitives), [design-kernel.md](design-kernel.md#interrupts-time-and-entropy), [design-network-stack.md](design-network-stack.md#one-owner-one-step) |
| **The system configuration is one manifest, proved at build time.** The build packs every configured domain, principal, image, budget, grant, device, facet and introduction into one checked manifest. Its fifteen properties enforce unique device ownership, platform confinement and hostile-input separation, a system domain that holds no network grant, the dedicated PCIe holder, console ownership, valid service targets, budgets, grants, rescue closure and domain creation feasibility. `system_reserve` leaves normalized configuration headroom unassigned to service children, by default one quarter; the system runtime runs directly in the aggregate `system` group without a separate cap. This headroom is not a CPU-supply or deadline guarantee, and shipped configurations undergo independent watchdog and control-latency tests. The device service checks the machine's actual placement and console path at boot. Every consumer reads the same packed configuration. | Security configuration has one checked source. Ordinary group quotas express its CPU hierarchy without an additional runtime group or replenishment mechanism; temporal liveness remains a separate verification obligation. | [design-system.md](design-system.md#the-manifest), [Chokepoint checks](#chokepoint-checks) |
| **A device goes where its capabilities are installed, and that is configuration.** Each device goes to exactly one domain, named by the system manifest, and that domain's creation gives it: the default puts the block device in the storage domain, the network device in the network domain, the TPM in the vault's domain, and the UARTs of the console and the host link in the system domain, beside the console and host link services, and the remaining slow devices (GPIO, I2C, SPI, the mailbox, the RTC) in one devices domain, outside the trusted base; on every PCIe platform, PCIe configuration space alone goes to the PCIe domain, which runs the PCIe enumerator and is in the trusted base whole. On a board where a DMA device is unconfined, the release configuration gives each such device a domain of its own; a development build may merge them. | The user's decision that drivers are Erlang makes a driver a process in whichever domain holds its device, so placement is one rule of configuration policy and no new mechanism. One ERTS per domain is why devices are grouped; a domain that parses hostile media or packets must never hold a device whose DMA is the whole machine. | [design-system.md](design-system.md#devices), [design-system.md](design-system.md#drivers) |
| **Storage and networking are services in Erlang domains of their own.** Partitions are windows the device service grants; media and packets are parsed only inside the domain that owns them, each parser in a supervised process; the block and network drivers are processes of the same domains. | The user's decision that system code is Erlang makes the file systems and the network stack erXos's own; a crafted medium or packet then fails within one process inside one domain instead of corrupting memory. | [design-storage.md](design-storage.md), [Networking](#networking) |
| **Storage keeps proven formats.** Read-only images use the EROFS format under a hash tree checked where they are consumed, read by an Erlang reader in every runtime and written on the host by fsimg, which also verifies every image it writes; read-write storage is erXos's own F2FS, in Erlang, with littlefs as its stopgap; FAT partitions serve removable media and exchange. | The user chose littlefs, then F2FS; EROFS, F2FS and FAT are existing formats with independent implementations to check against: fsimg, the owner's tool, writes and verifies EROFS and FAT images, and Linux's F2FS checks erXos's F2FS. erXos's images need not be readable by Linux; fsimg's verify and erXos's own reader check them. | [design-storage.md](design-storage.md#data-model) |
| **The system updates through two slots and a supervised trial boot, and the boot-selection record is its whole state.** The record names the committed slot C, and with the firmware's one-shot trial request it has two states: `normal(C)`, which boots C and lets the spare be written, and `trial(S)`, which boots the spare S once, after which the machine returns to C unless S is committed by rewriting the record to name it. Whether a spare is complete is decided by verifying it at boot against its update manifest, which the slot writer writes last, into the spare's manifest window, so a partial spare is not bootable; a commit is the record naming S, and a failed trial the record still naming C after one. | The user chose A/B updates; a power cut at any point leaves a machine that boots a complete system. With the spare's completeness checked where it is booted, no progress needs recording, and the update's states are the two the firmware already keeps. | [design-storage.md](design-storage.md#system-updates) |
| **The network stack is erXos's own, in Erlang, translated from FreeBSD's default TCP stack and its `netinet` and `netinet6`, pinned at FreeBSD 16 commit `975e3605ebb1`, with no stopgap stack before it; loss detection and congestion control are seams from the start, and RACK-TLP and BBR come later behind them. It is an ordinary OTP application, usable outside erXos.** | The user's decision: "take freebsd stack as a reference and translate logic to erlang ... so we don't discover problems from scratch", translating FreeBSD's decisions, not its structure, against one pinned tree; the pin is the FreeBSD 16 that the test host runs, and from the FreeBSD 15.1 the translation was read only changes the wire can see and real bug fixes are ported, since the aim is a stack that works, not one equivalent line by line. The user also asked for a stack "that can be used independently from erXos". System code is Erlang; FreeBSD's logic carries its interoperability and is BSD-licensed, and FreeBSD's TCP test suite and the FreeBSD test host are ready oracles; a stopgap stack would be a new stopgap, where nothing ships before the user says so. The default stack is the one FreeBSD runs and its test suite checks, where RACK and BBR are each a second TCP implementation, so the user deferred RACK. Whether TCP's fast path needs native code is measured on erXos's kernel, never on the stopgap. | [Networking](#networking), [design-network-stack.md](design-network-stack.md) |
| **A domain that other machines reach is a distribution node there too.** Each exposed domain carries its own distribution connections over the network service, under its own node name; a domain that is not exposed looks unreachable from other machines. A release build carries these connections only over OTP's TLS carrier. | The user's decision. Every domain is a node inside the machine already, so stock distribution semantics hold per domain, links, monitors and `noconnection` at a domain's end included; no pid is rewritten inside a term; and no term decoder or re-encoder runs in the network domain. It costs one connection per exposed domain per remote node, and remote nodes see the machine's domain structure. The TLS carrier is the user's decision too: the plain carrier authenticates by an MD5 challenge over a shared cookie and encrypts nothing; development builds, which run trusted code only, allow both. | [Networking](#networking), [design-network-stack.md](design-network-stack.md#distribution-to-other-machines) |
| **The trusted base parses no network traffic.** The system domain holds no `net` grant: the manifest check refuses one and the network service's mint refuses the system domain as a grantee. Whatever in the trusted base would need the network runs in a service domain; the network utilities and root's programs run in root's session, which holds `net`. | The user's decision. No socket's stream, push or exit enters the system domain, whose queue to a domain drops a message past `system_queue` and ends the domain at any other signal past it, so the socket protocol needs no case for that queue and the system domain no case for sockets. | [design-system.md](design-system.md#the-manifest), [design-network-stack.md](design-network-stack.md#the-grant) |
| **Cryptography is OpenSSL 3.5, and a small verifier checks update signatures.** OTP's `crypto`, `ssl` and `ssh` use OpenSSL 3.5. The update service checks every update's Ed25519 signature with a small verifier, a development build's against the development key the build embeds, with which the host tool signs what it sends over the host link; Monocypher is the candidate. | The user's decision. OpenSSL 3.5 is a long-term-support series, supported until 2030-04-08, under Apache-2.0, and OTP's `crypto` is written against OpenSSL. A small verifier keeps the full library out of the system domain ([research](research-boards-storage.md#cryptography-libraries)). | [Dependencies](#dependencies), [design-storage.md](design-storage.md#system-updates) |
| **erXos's own code is BSD-2-Clause, copyright Stanislav Sedov <stas@deglitch.com>; every image carries its third-party notices, and every changed third-party file says so.** | The user's decision; the dependencies' licences require their notices with every copy, and Apache-2.0 and the Zlib licence require changed files to be marked. | [Licences and notices](#licences-and-notices) |
| **A path is the face of a capability.** Every domain resolves paths through its own namespace, a table from mount points to local providers and to grants at file servers, named by pid, with no machine-wide root; binding and mounting never add authority. | The user adopted Plan 9's per-process namespaces. Holding a path is holding a pid, so the server's exports to the domain decide what a path reaches, with no second check. | [design-files.md](design-files.md) |
| **File servers keep their grants' roots and speak 9P2000.L.** A grant's root and rights live at its server. A program holds no fid: its handler narrows a grant by walking fids at the server, and what passing a file shares is the session's open-file description. The file protocol's operations and semantics are exactly 9P2000.L's, `symlink` included; on erXos's connections each operation travels as an Erlang term with 9P2000.L's fields, in frames to single-use aliases, with bulk bytes in shared memory; at the host link and on the network it is encoded as 9P2000.L's messages by the generated codec `erx_9p`, with `msize` bounding only those edges, so in development configurations QEMU's virtio-9p serves a host directory to a host-tree domain, mounted at `/host`, and any 9P client mounts an erXos server. A file's identity is the server's domain, the tree its grant roots (the attach name), its qid path, which the server keeps unique within the tree and never reuses within a boot, and `getattr`'s `data_version`, and no request carries a deadline. Erlang services serve trees through the `erx_fs` behaviour, the device service as `/dev`; `/proc` is served by `erx_procfs` in each reader's own runtime, over its inspect facet. | The user adopted Plan 9's file servers, and decided on standard 9P2000.L rather than an erXos variant. A root the server holds cannot be walked out of by a compromised client; one resolver and one protocol serve Erlang and native clients alike; and the protocol's semantics come with an independent oracle and existing clients and servers at the edges. | [design-files.md](design-files.md#the-file-protocol) |
| **System values are one read-only tree with many views; there is no `sysctl`.** Every system-wide value (the machine's uptime, CPUs and memory, a domain's runtime figures such as its run queue) is an attribute of the inspection schema's tree, and `/proc` is that tree as files. `erx:i/1`, `/proc`, the host tool, the shell's commands and a `sysctl(3)` reader in the POSIX-lite personality are views of it, each with the value's one status and reporter; the reader maps FreeBSD's names onto `/proc/status` through the program's namespace and answers `ENOENT` for a value that is not `ok`. No view writes: configuration is the system manifest. Who sees what is the inspect facet's scope, the security boundary, times the root of the `/proc` grant, least privilege for one program; the inspector keeps no per-path allow list. | The user's decision, preferring Plan 9's way of serving system values through files: one tree gives one permission model, one name and one status per value, where FreeBSD's split between `sysctl` and `procfs` needs two of each, and a writable value would be a second, unproven way to change the machine. It binds the shell, the file servers, the runtime's figures and the C library seam. | [design-live.md](design-live.md#system-values-one-tree-many-views) |
| **Every route between domains starts at a declared facet, and a new need has one of three homes.** A domain reaches a service of another domain only through a facet the domain service minted, or through a name an operation of that facet handed out (a socket's process, a session's line, a fid). Every facet is an instance, a service row of the system manifest, of an interface that `abi/services` declares, and each interface file cites the design section that justifies it; a grantee holds the facet under the service row's name, so `data` is an instance of `files` and `storage_ctl` one of `driver_control`. One route lies outside the rule: the runtime protocol through which the system domain, as root task, builds, connects and inspects every domain ([design-domains.md](design-domains.md#messages-between-the-domain-service-and-a-runtime)). A new need adds no facet, request shape or validator of its own; it goes to one of three homes. **State someone reads** is a path of the inspection schema, `abi/inspection.txt`, reported by its owner, gated by the inspect facet's scope and the schema's `visible` classes, and shown at `/proc`. **Bytes someone keeps, or a thing someone commands,** is a file tree its owner serves with `erx_fs` and the reader mounts (`erx_ns:mount({facet, Name}, ...)`), with one-shot control as a `ctl` file in that tree. **A live conversation** (sockets, a tty's bytes, the web relay, the program channel, the host link) is a protocol declared in `abi/services` or `abi/protocols`, with a design of its own. The test for the next case: if `cat` can answer it, it is an inspection path; if `cp` or `echo > ctl` can do it, it is a file in its owner's tree; otherwise it is a protocol, which is a design decision. The inspector crosses a domain boundary once, as records, through the typed `inspect` interface, and `/proc` is a view of it in the reader's own runtime. | The user's decision, asked for as a simple and elegant answer to such needs in general. One way in for each kind of thing keeps who-sees-what to two gates, the facet's scope and the grant's root, and leaves no per-need mechanism to review: the kernel log is the declared path `[kernel, log]`, not a facet of its own. Records cross the boundary rather than `/proc` text because `erx:i`, `top` and the browser need each value's status, reporter and type; serving `/proc` in the reader's runtime keeps a file protocol's fid state, text rendering and snapshots out of the trusted base and charges them to the reader. | [design-live.md](design-live.md#the-inspect-service), [design-domains.md](design-domains.md#facets) |
| **Code is named by its hash.** Every module and native image is a blob named by its SHA-256; manifests map names to hashes; a fetch checks the bytes against the hash; the host sends only missing blobs; overlays are manifests, kept per principal and dropped when the release they overlay changes. | The user adopted content-addressed code: a version is its hash, sharing and rollback fall out, and a store or a transfer that changes a byte fails the load. A hash gives identity, never trust. | [design-live.md](design-live.md#the-code-store) |
| **Keys stay in the vault.** Principals' private keys and secrets live in the vault's domain, sealed under a master key per principal that each of its credential slots wraps; a passphrase slot stretches the passphrase with Argon2id, and every slot's key mixes in a secret from the machine's sealing backend; a domain authenticates through a key facet that signs one protocol's input for one purpose. | The user adopted Plan 9's factotum, as the vault, and chose Argon2id, layered keys and a sealing interface: a defect in a network-facing domain gives away signatures for one purpose while the grant lives, never a key; a passphrase change re-wraps one slot, a new kind of slot joins without touching the keys, and where the machine holds a secret of its own, a copied medium opens no slot. | [design-system.md](design-system.md#the-vault) |
| **A program is a port of its session, with the authority it was handed.** A program runs in a sub-space that its session's domain creates within its own budget and group, and in Erlang it is a port of the session's runtime: owned by a process, linked, closed with its owner, spoken to by messages, reporting `{exit_status, N}`. The session's port driver creates the program's spaces, a threadless anchor under its starter's anchor, or under the session's space for a program the shell starts, and an image below the anchor, maps the image through `liberx`'s loader, creates the program's channel, installs its pipe ends and the startup message, and starts its first thread. A sub-space has no domain id, no node identity, no export table, no facet and no connection; every request a program makes, files, spawn, wait, exec, fork, kill, terminal modes, is a message on its channel to its handler, an Erlang process of the session that acts with the session's authority after checking the program's own table. File data does not cross the channel per byte: the handler relays the request terms over the session's connection to the file server, and the bytes move through the program's data area, which the session supplies and the handler fills and drains. A program's authority is what its starter handed it, never the kind of command it is; its namespace is grants its starter derived from its own, held at the servers and in the session's state, never by the program. | The user's decisions: a POSIX-ish interface, so that UNIX programs need not be ported to Erlang, and security from capabilities, not from which programs may start which. A program's whole world is its session, as Plan 9's kernel is to its processes: it holds no grant's pid, speaks to no file server, and cannot be a confused deputy for one, so confinement holds by construction; it needs no domain, no facets and no identity of its own ([Alternatives considered](#alternatives-considered)). | [design-programs.md](design-programs.md#a-program-is-a-port), [design-programs.md](design-programs.md#the-channel), [design-programs.md](design-programs.md#the-handler) |
| **A program starts what its `/bin` lists.** A program of the boot image; an executable reached through an `rx` grant, which no grant holds together with `rw`; or an Erlang command, which runs in a command domain with exactly its capabilities. `system` and `popen` run `rc`. | The user's decisions: a program runs a file only through an `rx` grant, so it never runs what it could rewrite, and `system` and `popen` hand their command to `rc`. | [design-programs.md](design-programs.md#what-a-program-can-start) |
| **Descriptors, pipes and signals are `liberx`'s.** Descriptors are a table in the program's library over pipe ends and open files; each pipe end is installed into the program's sub-space by its session's pipe server, which installs an end for each child a program starts; open files are the session's grants, which the program names by descriptor and the handler relays, sharing their offsets; the POSIX signals a program may catch arrive as reports on its channel, which its own event executor raises as vCPU upcalls, and are delivered only outside the library's critical sections, while `SIGKILL` is the session's stop of the program's anchor, `SIGSTOP` its pause of the program's image, and `SIGCONT` its resume of the image before the report. | Pipe ends installed by one party make the end of the stream a consequence of who holds them, and the kernel stays free of POSIX. | [design-programs.md](design-programs.md#descriptors-and-files), [design-programs.md](design-programs.md#signals-in-liberx), [design-pipes.md](design-pipes.md) |
| **Signals have FreeBSD's numbers.** erXos's musl, `liberx`, the program protocol's names and the command shell's `kill` all take FreeBSD 15.1's signal numbers, names and default actions from one signal table in `abi/erx_abi.txt`, from which musl's signal header is generated: `SIGSTOP` 17, `SIGTSTP` 18, `SIGCONT` 19, `SIGINFO` 29, `SIGRTMIN` 65 to `SIGRTMAX` 126. A number the table does not list is not a signal anywhere, and no number crosses a program's channel: frames carry names. | The user's decision. The shell already uses FreeBSD's numbers, and programs built on musl would otherwise use Linux's, so users would meet two numberings; where UNIX systems differ erXos follows FreeBSD, and programs are ported at the source level, so no binary depends on Linux's numbers. | [design-programs.md](design-programs.md#signal-numbers), [design-shell.md](design-shell.md#job-control) |
| **A program's tree ends with it.** A program ends with the program or session that started it, like a job tree; a long-running service starts under a supervisor, never by detaching, so nothing is orphaned. | The user's decision. | [design-programs.md](design-programs.md#a-programs-end) |
| **A second tier grows toward QNX.** `fork`, first as an eager copy; the `exec` family, which runs the new image in a fresh image space under the program's anchor, a threadless space that lives as long as the program and parents its images and its children, so `exec` keeps the program's children and never narrows what the program can message, a narrower program needing a spawn; dynamic shared libraries; mappings of files; pseudo-terminals with process groups and sessions, on which full-screen programs run. No Linux binary compatibility and no Linux virtual machine. | The user's decisions: at least QNX's level, with dynamic libraries; Linux binaries and a Linux virtual machine rejected. | [design-programs.md](design-programs.md#the-second-tier) |
| **A command shell with rc's language, and toybox.** Each session can run a shell in Erlang that speaks Plan 9's rc, with emacs-style editing and job control; builtins, Erlang commands and toybox's applets, with `wak` as awk, share one command namespace, of which programs see the Erlang and program commands their `/bin` lists, run with the programs' own capabilities; every pipe carries text, and each command behaves like FreeBSD's command of the same name, the Erlang commands with FreeBSD 15.1 as their test oracle, printing a value erXos does not measure as FreeBSD prints a missing one, `-` or nothing. Live values with their statuses are the Erlang shell's and the inspector's. | The user's decisions; rc's single quoting rule and list variables remove the rescanning that makes POSIX shells error-prone, and a shell in Erlang reaches the inspector and the code store directly. Text in every pipe keeps one kind of pipe and makes the commands UNIX's to their users (principle 5), with no renderer, framing or predicate language at the edge between commands and programs. A shell compatible with tcsh is a possible addition in the roadmap. | [design-shell.md](design-shell.md) |
| **Release consoles log in.** In a release build both console lines, the UART and the host link, start with a login, and a session runs in its principal's own domain; an Erlang shell in the system domain needs the system-shell facet, which the console grants only to a login at a secure line by a principal the manifest names: in a development build `root`, logged in at the UART at boot and at the host link's `console` line when the host opens it, and in a release build by default nobody. | Evaluating an expression in the system domain is as strong as installing code there, so it needs a facet as strong as the install facet. | [design-live.md](design-live.md#the-console) |
| **Secure console lines.** Each of the two console lines, the UART and the host link, has a `secure` attribute in the system manifest, as UNIX's `/etc/ttys` marks the terminals where root may log in; a release manifest marks both secure by default and may clear either. The system-shell facet belongs to a login at a secure line, never to a session: the console grants it, holds it, connects the system shell at that line alone and ends it with the login. | Evaluating in the system domain is the system domain's authority. Tying the facet to a login at a line, not to a session, leaves every route into a session without it by construction, so the routes into a principal's own sessions, `erx:attach` among them as `screen -r` is on UNIX, and a terminal on a display, need no list. | [design-live.md](design-live.md#the-console) |
| **A terminal is a program of its session; a display composites and routes input.** A user's terminal, `erx_term`, runs in the user's session domain, makes its window through the session's grant and is the master of a tty of the session's terminal relay. The display domain composites windows and routes input, as rio or an X server does: it parses no program's output, holds no console line and starts no program in a session. How a person logs in at a display is not designed; a display serves the one session its manifest entry names, started without a login. | A terminal in the display domain would make the display parse every session's output and decide, through console lines and tokens, which session each window serves; as a client of its own session, as xterm is of X, a terminal needs neither, and the display keeps only the trust an X server has: it sees every keystroke it routes and every pixel it shows. | [design-display.md](design-display.md#the-terminal), [design-display.md](design-display.md#a-displays-session) |
| **One width table.** A character's column width has one source: the terminal generator writes, from the width rule of `abi/terminal.txt` and the Unicode data OTP 29.1.2 carries, the table of the terminal emulator `erx_vt`, musl's `wcwidth` tables and `erx_width`, which `prim_tty:wcwidth/1` answers from. | A program, the shell's line editor and the terminal must agree on where the cursor is after a wide or combining character; three tables from three Unicode versions drift apart. | [design-display.md](design-display.md#cells-and-the-grid-state), [design-runtime.md](design-runtime.md#the-c-library-seam) |
| **Text is UTF-8; system identifiers are ASCII; a terminal is a tty.** Data is UTF-8 everywhere; an identifier matches `[a-z0-9][a-z0-9_-]*`, at most 63 bytes, checked once at creation and never normalised; file names are the bytes given, valid UTF-8, never normalised. What a program writes reaches a tty unchanged, and the tty does only `termios` processing, such as newline to CR-LF; a tty has many writers. Text labelled with its source is escaped by whatever displays it, which renders controls, bidirectional and invisible format characters and invalid UTF-8 visibly, from a table generated from Unicode's data. `/proc`, whose files are inspector output, writes such text already escaped, by an injective escape, so `cat` of it shows no raw control. | The user's decision: output functions do not touch the data, as on UNIX and QNX, and a program can send the terminal any escape code, as over `ssh`. A label is a claim about a source, so a display keeps it to one honest line, as `ls` does with odd file names. The user's decision for `/proc`: its files are inspector output, so the tree escapes what it writes, and `cat`, pipes and files keep passing bytes unchanged. | [design-live.md](design-live.md#the-tty), [design-live.md](design-live.md#attributed-text), [design-system.md](design-system.md#identifiers), [design-files.md](design-files.md#text-in-file-names) |
| **A boot image is admitted, and the root task started, from one startup plan under a charge model the kernel verifies at boot.** The packer and the kernel run the same C17 `erx_root_plan` over the boot image and the backend's charge model; the packer admits an image only if the plan fits the platform's memory less the model's bound on the kernel's own boot use, and the kernel refuses to start the root task when its pool's real capacity or the charges it applied disagree with the plan. | Admission rests on the production plan and never on a declared baseline ([plan.md](plan.md#m0-the-tree-the-toolchain-and-the-oracle)); one function run on both sides makes the host's admission a prediction the kernel checks, so no root task runs that its image did not pay for, and a bootloader's memory report is never an input. | [design-kernel.md](design-kernel.md#the-startup-plan-and-its-charge-evidence), [design-abi.md](design-abi.md#canonical-source-packing-and-checking) |

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
  and its licence
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

| Rule | Check | Owner |
| --- | --- | --- |
| the kernel's rules, each listed with its check in the kernel's own table: among them, only the capability table's code reads a slot, only `erx_cap_slot_clear` clears one and only the listed calls install one; a UTCB's fields and a sequence-counted record's are reached only through their generated accessors, which load each field once per decision; a memory window is reached only through `erx_window_read` and `erx_window_write`; the type of a user address converts to no pointer, and the ABI file's grammar has no pointer type; objects hold no counted reference to each other, and only threads count references; only the charging funnel allocates; no FP or SIMD; recursion only through `musttail` | relocations, disassembly and clang's syntax trees of the kernel's objects and image, each with a fixture that seeds one violation | [design-kernel.md](design-kernel.md#chokepoint-checks), [design-kernel.md](design-kernel.md#budgets) |
| an architecture's terms appear only in its layer and its documents | `make check-arch-terms`: no term of an architecture's checked-in list, `hw/arch_terms/<arch>.txt`, appears in generic sources, generic generated files, `abi/erx_abi.txt` or a generic design document; the architecture's layer and files, its binding, the platform binding, the research records and this document's dependency table, which names every dependency, board firmware included, are exempt, and an architecture's name is not one of its terms | [design-kernel.md](design-kernel.md#chokepoint-checks) |
| ERTS's objects import from outside themselves only `liberx`'s calls and the names in `sys/erxos/imports.txt`, and `sys/erxos` holds no conditional on a backend | `make check-runtime-seam`: the undefined symbols of the objects before each link, the native image's calls into musl's seam, the two targets' configure results and a source scan | [design-runtime.md](design-runtime.md#what-erts-imports) |
| only `ethr_thr_create` calls `erx_pthread_create_executor`, and only `erts_start_schedulers` asks it to | a source check | [design-runtime.md](design-runtime.md#threads-and-synchronisation) |
| only `liberx` issues kernel calls, and only its `fiasco` backend includes a Fiasco header or executes Fiasco's call sequence | disassembly of every user-mode image; include scans | [design-kernel.md](design-kernel.md#chokepoint-checks) |
| only a space's creator installs capabilities into its table unasked, the domain library installs into a domain only from the system domain's own table, and only a sub-space's creator copies it | the domain library's installs come from one checked table; a source check over `liberx`'s system layer finds `erx_cap_pass` only in the domain library's one install function, and `erx_space_copy` only in its copier and in the session port driver's `fork` path, with a seeded violation; the generator refuses a pass set for spaces; domain tests that `erx_cap_pass` into a space's table and `erx_space_copy` fail on a space the caller did not create, and that a space's capability passed on carries `INSPECT` alone | [design-system.md](design-system.md#invariants) A1, A7; [design-system.md](design-system.md#the-domain-library) |
| only `erx_ns`'s process writes a runtime's namespace table, and only `prim_file:set_cwd/1` its working directory's store, so a resolution reads one table a single writer made | a source check over the runtime's Erlang that `persistent_term:put/2` and `erase/1` of the table's key appear only in `erx_ns`, and `erx_set_cwd_nif/1` is called only from `set_cwd/1`, each with a seeded violation | [design-files.md](design-files.md#building-binding-and-mounting) |
| only an Erlang command that declares a service's facet with `-erx_needs` names a module of that service of the system domain, and no other module of the command shell does, so a session without the facet refuses the command with `no_facet` before it starts | a source check over erlang/apps' Erlang sources, the service's modules read from its applications (CommandNeeds) | [design-shell.md](design-shell.md#interfaces) |
| a facet enters a domain's table only as an instance of a declared interface: `abi/services` declares each interface and the first design section its file cites justifies it, and the system manifest's service and facet rows name each facet's server, grantee and interface; a grantee holds a facet under its service row's name, and the domain service's one funnel for a domain's facets, `erx_domain_srv:facets/1`, which every create spec, session start and mint passes, refuses a key that is not a manifest service's name, from a table the build generates from the manifest | the generated table and the funnel's refusal, with a host test that a create spec naming an undeclared facet fails with `{bad_spec, facets}`; a source check over the Erlang sources' facet lookups, `-erx_needs`, mounts and mints, the manifest's interfaces and the cited headings (FacetNames) as a second line, which catches a name the code uses that no grant could supply; each with a seeded violation | [design-abi.md](design-abi.md#services-facets-and-their-parameter-schemas), [design-domains.md](design-domains.md#facets) |
| a file client sends a request only through its one request function, which checks it against the protocol's grammar and the entry's rights and refuses a walk naming `.`, `..` or an empty name, so a path reaches a server only through `erx_path`'s actions | a source check that `erx_file_remote`'s send is referenced only from that function, with a seeded violation | [design-files.md](design-files.md#erlang-clients-prim_file-and-erx_file_remote) F2 |
| system identifiers are made only by `erx_ident:new/1`, and a record that names something is built only by its owning module's constructor | `erx_facet` converts every argument an operation declares as an identifier; each constructor checks its name with `erx_ident:new/1`; a check over the system release's syntax trees fails on a record expression of such a record outside its owning module, with a seeded violation; Dialyzer checks the opaque type besides | [design-system.md](design-system.md#identifiers) |
| only the funnel reads a lane's ring; only the three export paths (encoding an own pid or alias into a frame for a peer, a spawn into the domain, the explicit export call) write the export table; privileged service helpers take handles a facet minted from its own scope, never bare request names | a source check over `liberx` and the runtime that the ring's read side is referenced only from the funnel; a source check over the runtime's export table that its insert is referenced only from the three paths; a check over generated service interfaces, each with a seeded violation | [design-domains.md](design-domains.md#invariants) D3, D4; [design-domains.md](design-domains.md#exports); [design-domains.md](design-domains.md#authority) |
| a driver reaches its device only through the device NIF, and the NIF reaches registers only through the generated accessors, by register name; only the NIF writes a device address, into a register the SVD source marks as holding one or into a descriptor's address fields and addressing flags | a link check that the generated register accessors are referenced only from the device NIF's native part, and that no other NIF in a driver application's release touches device memory; a check over the driver applications' BEAM files that register access goes through `erx_device`; the generator's refusal of a register without its address mark; a source check that the marked registers' writers and the generated queue code's address and addressing-flag writers are referenced only from the NIF's one address function, each with a seeded violation | [design-system.md](design-system.md#drivers), [design-runtime.md](design-runtime.md#the-device-nif) |
| system-domain code creates atoms only through calls on an allowlist: no `list_to_atom`, `binary_to_atom`, unsafe `binary_to_term` or similar on data from a request, except the one function that makes a node name within the requesting principal's `names` quota | a check over the system release's BEAM files with the compiler's call graph | [design-domains.md](design-domains.md#invariants) D5 |
| only the adapter in `sys/erxos` includes a `liberx` header inside ERTS; the adapter's event handling runs only at the safe point and before parking | include scans; a call-graph check | [design-runtime.md](design-runtime.md#invariants) R1 |
| only the console's driver writes the console's UART after boot: every system manifest names the console's UART by device-tree path and places its unit in the system domain, the device service refusing at boot a manifest whose console path is not the one `/chosen/stdout-path` names; the kernel's early console, which carries only the kernel's own log, shares the UART in time | a check over the driver applications' BEAM files with the compiler's call graph that the UART's transmit register is reached only from the driver; a relocation check that only the kernel's log writes its early console; each with a seeded violation | [design-live.md](design-live.md#the-console) |
| the host tool prints guest bytes raw only from the terminal stream of `erx console`, and everything else it prints from the guest through the line escape | a source check on its output calls, with a seeded violation | [design-live.md](design-live.md#invariants) V9 |
| only the early-console writer writes a UART's registers in the kernel | relocations of the kernel's image: the UART registers referenced only from the early-console writer, with a seeded violation | [design-kernel.md](design-kernel.md#chokepoint-checks) |
| only the code service writes a hot store or an overlay, and only `erx_code` calls `erx_code:install_beam/2` | a check over the system release's BEAM files with the compiler's call graph, with a seeded violation; `install_beam/2` also refuses every other caller at run time | [design-live.md](design-live.md#the-code-store) |
| every exported function of `liberx`'s program layer raises the signal depth, and the program layer never calls musl's allocator or `stdio` | a check over `liberx`'s syntax trees that each such function opens with the entry macro; a check of the program layer's objects' undefined symbols | [design-programs.md](design-programs.md#signals-in-liberx) |
| only `erx_elf_plan` reads an executable's headers, and only `erx_image_plan` reads an image manifest's segments, the boot image validator through it; only `liberx`'s loader, `erx_exec`, maps an executable file's code into a program | a link check that the ELF reader's symbols appear only in `erx_exec`, and that `liberx`'s one function that maps code is referenced only from `erx_exec`, each with a seeded violation; a source check that only `erx_image_plan` decodes a manifest's segments, with a seeded violation | [design-programs.md](design-programs.md#what-a-program-can-start) |
| the event executor of `liberx` takes no kept lock | a call-graph check over `liberx` from the event executor's entry, with a seeded violation | [design-programs.md](design-programs.md#signals-in-liberx) |
| only the channel's send writes a program's outbound lane, so every request is recorded as an obligation in the operation table | a source check over `liberx` that finds stores to the outbound lane's ring and header only in the channel's send, with a seeded violation | [design-programs.md](design-programs.md#signals-in-liberx) |
| only the obligation-making functions call `erx_op_hold`: the channel's send, the pipe core's claim of a control record, an end's reservation of room for `sendmsg` and `fork`'s locking step | a call-graph check over `liberx` that finds `erx_op_hold` called only from those four functions, with a seeded violation | [design-programs.md](design-programs.md#signals-in-liberx) |
| only `erx_shm_copy` reads a pipe's shared pages | a source check over `liberx` and the pipe NIF, with a seeded violation | [design-pipes.md](design-pipes.md#the-ring) |
| the system manifest holds its declared ownership, confinement, authority, resource and boot properties; service grants leave `system_reserve` as normalized configuration headroom, which is separate from temporal scheduling guarantees | the manifest's fourteen-property check before packing, with a seeded violation per property; independent workload tests for watchdog and control latency | [design-system.md](design-system.md#the-manifest) |
| only `erx_dom_destroy`, `erx_dom_disconnect` and `erx_dom_retire` destroy a domain's budgets, its outer budget among them once no connection holds a child of it, and the domain library installs into a domain's table only through `erx_dom_install`, never a gate of another domain | a source check over `liberx`'s system layer that budget destruction and the install calls are referenced only from those functions, with a seeded violation | [design-system.md](design-system.md#the-domain-library) |
| only the manifest's two readers, the generated C reader and the Erlang module `erx_manifest`, read the system manifest | a source check and a check over the system release's BEAM files that the manifest is read only through them, each with a seeded violation | [design-system.md](design-system.md#the-manifest) |
| in OTP's applications, only `gen`, `io`, `gen_server`, `gen_statem`, the io servers `group`, `file_io_server` and `application_master`, the file client `erx_file_remote`, and `erts_internal`, whose `dist_spawn_init` takes a spawn's argument list, take a message out of the `{erx_origin, D, Msg}` envelope | a source check over the Erlang modules under `otp/` that only those modules match a tuple tagged `erx_origin`, with a seeded extra site; erXos's own applications under `erlang/` each own their protocol and take the envelope whole | [design-domains.md](design-domains.md#invariants) D18 |
| no release lets `global` or `pg` span domains | a release-build check that fails the build on a release that sets `connect_all` to true, with a seeded violation | [design-runtime.md](design-runtime.md#erlang-visible-behaviour) |
| no generated file is checked in or edited | the generated tree's refusal of a repository file at a generated output's path (`Erx::Generated.ensure`); the stamp of `build/gen/`, which regenerates an edited output | [One source](#one-source-for-the-abi-and-the-hardware) |
| a file of an imported tree that differs from its import says so, and every file in an image has known provenance and an allowed licence | each file's SHA-256 against the record in its tree's `ORIGIN.md`, and its header searched for erXos's notice; every packed file's provenance and licence, from the linker's maps, the compiler's dependency files and the packer's list | [Licences and notices](#licences-and-notices) |
| only the domain library's one ending function destroys a domain's budget, which deletes its space with everything else it paid for, and the domain service reaches it only after it has let go of everything it was given of the domain | a source check over `liberx`'s system layer that a domain's budget is destroyed only in that function, with a seeded violation; a check over the system release's BEAM files with the compiler's call graph that the NIF behind it is called only from the domain service's ending path | [design-system.md](design-system.md#ending-a-domain) |
| only the slot writer writes a slot or the boot-selection record | the device service derives those windows from the medium layout and grants them to the slot writer alone; a test that every other request for them fails | [design-storage.md](design-storage.md#system-updates) |
| on a trial boot, nothing but the record is written | the block driver's one write function checks the boot value in its view of the machine page; a check over the storage domain's BEAM files with the compiler's call graph that the device NIF's post (`erx_device:post/4`) is reached only from the driver's write path, the one module that builds every request it posts, with a seeded violation; a QEMU test of every client's writes on a trial boot | [design-storage.md](design-storage.md#system-updates) U4 |
| only the trial request and the boot-time key read reach a firmware mailbox, so only `ERX_END_TRIAL` sets the firmware's trial request, and the board's key is read only at boot | relocations of the kernel's image: the mailbox's registers referenced only from those two functions, and the key read and its derivation only from boot code, in the boot-only section the kernel unmaps before the root task starts, each with a seeded violation | [design-kernel.md](design-kernel.md#chokepoint-checks), [design-platforms.md](design-platforms.md#device-secrets) |
| only `liberx`'s root-task entry reads the device-secret page, and only the vault's domain, whose release alone the boot image marks with `ERX_ENTRY_SEAL`, maps the sealing secret derived from it | the device-secret page is created without `DUP`, `GIVE`, `CHILD`, `WRITE` and `DESTROY`, so its one capability is the root task's and no call can copy or move it (K2); the root-task entry derives the sealing secret into the sealing page, a memory object of the root budget, then unmaps both pages and closes its capability to the device-secret page before ERTS starts, so nothing that runs Erlang code maps either secret; the domain library keeps the sealing page's one capability, never passes it, and maps the page read-only into the vault's domain alone; a link check that the device-secret page's slot is referenced only from the entry's one derivation function and the sealing page's slot only from that function and the domain library's one mapping of it; the packer sets `ERX_ENTRY_SEAL` only on the files of the release the build names as the vault's, and the boot validator accepts one contiguous run of them; a host test that the domain library's creation plan maps the sealing page for no release slice but that run and refuses that run while another living domain maps the sealing page; a QEMU test that after boot the system domain's space maps neither page | [design-system.md](design-system.md#the-vault), [design-kernel.md](design-kernel.md#the-boot-image), [design-platforms.md](design-platforms.md#device-secrets) |
| only storage domains hold windows on a data, FAT or vault's partition, and only the storage domain that serves the vault alone holds the vault's; only the slot writer holds the slots' and the record's; only the network domain holds the network device and only the vault's domain the TPM, so unverified media, packets and TPM responses are parsed only there, besides the block driver's parser of the partition table; the EROFS reader parses only blocks the hash-checking reader returns | the manifest check's properties at build time; a host test of the device service's derivation of windows and of device placement from the system manifest; a link check that the runtime's window read is referenced only from the hash-checking reader; a cross-reference check that the EROFS reader's modules reach an image only through `erx_verity:read/3` | [design-storage.md](design-storage.md#security), [design-system.md](design-system.md#devices), [Networking](#networking) |

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
  the stopgap are under the same rule; Fiasco's inherited C++ is exempt
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
| A driver of an unconfined device, or the device itself | everything its device's DMA can reach | nothing is enforced: the domain that holds the device is in the trusted base, and a release configuration gives such a device to a domain of its own, so that no domain that parses hostile media or packets holds one |
| The PCIe domain, its PCIe enumerator, or a PCIe device answering the enumerator | read and write every PCIe function's configuration space; enable memory decoding and bus mastering, and so let a function without an IOMMU stream reach any memory by DMA; answer configuration reads as a device likes | give a confined function's DMA any reach, since the IOMMU aborts every stream not bound to a window; reach a BAR or an MSI the device service did not derive for a driver's domain; touch the kernel's state, since configuration space is read in user mode and parsed in Erlang by a bounded parser with a fuzz target |
| The devices domain, or any slow device's driver in it | drive the slow devices, confined or not as each platform has them | reach PCIe configuration space, which only the PCIe domain holds; hold a device that parses hostile media or packets; reach another domain's memory, unless a configuration gives it an unconfined DMA device, which puts it in the trusted base as any holder of one |
| The host-link peer, development build | everything (it holds every facet but the system-shell facet, and the system shell at its `console` line, where `root` is logged in) | nothing more: development builds are for trusted code only |
| The host-link peer, release build | what the configured facets of its session allow | anything else; every byte it sends is checked with the host grammar and decoded safely |
| A device writing shared memory | write the rings and buffers it was given | make a driver, the kernel or a runtime trust what it wrote; every ring entry is validated by its consumer |
| Whoever wrote a storage medium's data partition, or an update image | choose every byte a file system reads from that partition, and what a development build installs through the host link; through a file-system domain that a crafted partition compromises, read and write every principal's files on that partition, and so rewrite those principals' persisted overlays and run code in their supervised domains at their next start | make that domain reach any other partition, the vault's partition and its key files included; persist an overlay into a domain of the system configuration or into the system domain, whose overlays are never persisted; change an EROFS image without its hash tree noticing; make a build install an update that its trusted key did not sign, an older one, or, in a release build, a development one |
| Whoever can write the boot medium | where nothing checks the boot image before the kernel runs, as on QEMU `virt`, whose trust root is the host, and on a board without secure boot: anything, the console's prompts included, so a passphrase typed there may be recorded; on a board with secure boot: put into a slot any boot image the board's key signed, an older one included | on a board with secure boot, run code the board's key did not sign; learn a secret from the boot image, which holds none ([design-platforms.md](design-platforms.md#trust-in-the-boot)) |
| Whoever can read a storage medium | read every file on it, the vault's sealed files included; under the vault's `none` backend, guess a principal's passphrase offline against its file, at one Argon2id derivation for each guess, and read the machine keys | under the `device` or `tpm` backend, open any slot away from the board, the machine's included; read a passphrase or a private key without guessing a passphrase; learn a secret from the boot image, which holds none |
| A network peer | send any packet to the network domain; once TCP distribution, TLS or SSH has authenticated it, act with the authority of the service or domain that accepted it | make the network domain do more than fail or drop traffic; reach any domain before it is authenticated, or beyond what the accepting service grants |
| The person at the console's UART, present at the machine | in a release build, log in, and then what the session's principal holds, with the system shell when the principal is one the manifest names for it, by default none; as presence at the machine, open a principal's slot made under another sealing backend, and enrol any principal of the system configuration that has no key file, choosing its first passphrase and then acting as it, which, with the vault's partition in hand as well, includes any principal whose file it deletes or replaces with one made under a weaker backend; in a development build, `root`'s session and the system shell, which the console opens at the UART at boot | enrol a principal whose key file it cannot delete; type expressions into the system domain except in the system shell of a login at a secure line; guess passphrases faster than the vault's limits per name and per line allow, or, under its `tpm` backend, than the TPM's lockout allows; inject terminal control sequences into anyone's terminal through text another party supplied |
| A person at a display | type into the terminals of the session the display's manifest entry names, which starts without a login, and so hold that principal's authority, the principal's other sessions included, as at a UNIX console that logs a user in automatically; open sibling terminals and the windows of that session's programs | reach the system shell, which opens only at a login at a secure console line, the UART or the host link; reach a session the manifest does not name for that display; open the principal's vault keys, enrol a principal, or count as presence at the machine ([design-display.md](design-display.md#a-displays-session)) |
| A compromised display domain | show a false screen, record every keystroke it routes and inject input into the windows it serves, as an X11 or Wayland server can: typing into a terminal's window, it has the authority of the shells in the terminals of the session introduced to it and what that session's principal reaches; read and write its display's clipboard where `snarf` is on | anything beyond: read a domain's memory or message a process it was not introduced to; start a program in a session; reach a session not introduced to it; reach the system shell, which no display carries; be attacked by what a program writes to a terminal, which never reaches it ([design-display.md](design-display.md#security)) |
| A domain holding a display facet with `events` | send any input event within the bounds of `input()` to that display, as a person at it would: type into and point at every window of the session the display's manifest entry names, hidden ones included through the overlapping policy's menu, and so hold that principal's authority, or drive a kiosk's application; type the reserved chord | read what the display shows or what is typed at it; reach a window's pixels; reach a window's files; anything a person at that display cannot do ([design-display.md](design-display.md#input-events)) |
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
estimates ([design-kernel.md](design-kernel.md#requirements)) and whose
stopgap's measured size is in the research record
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
  trees that services serve, and the 9P2000.L codec at the host link and
  on the network; the code service's decoder of the overlays and stores it
  reads back from a data partition; the update service's manifest decoder,
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
  grant to one grantee domain. By the user's decision a facet acts only
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
* **The stopgap is not hardened.** Development builds run trusted code
  only, and the security closure milestone runs on erXos's kernel.
* **Closed firmware, and verified boot only where secure boot is on.**
  The boards' firmware is Broadcom's binary: it loads the kernel and stays
  resident for the machine's life, with access to all memory. The firmware
  that starts CPUs and ends the machine stays resident on both boards,
  more privileged than the kernel. Both are trusted as any machine trusts
  its firmware. The Pi 5's firmware, its resident part included, and both
  boards' bootloaders live in the board's EEPROM, outside the slots, so an
  update does not change them
  ([design-platforms.md](design-platforms.md#firmware)). What checks a
  boot is the platform's
  ([design-platforms.md](design-platforms.md#trust-in-the-boot)): on QEMU
  `virt` the host, and on a board the firmware's secure boot, which
  checks each slot's boot image, and through it the EROFS images' root
  hashes, against the board's key. Where nothing checks it, inside a QEMU
  guest and on a board without secure boot, whoever can write the boot
  medium controls the machine, its console's prompts included, so console
  enrolment is only as trustworthy as the medium. Even with secure boot no
  firmware refuses an older signed image: the Pi 4's has no anti-rollback,
  the Pi 5's documents describe none, and erXos's security version guards
  only what an update installs
  ([design-storage.md](design-storage.md#system-updates)).
* **A persisted overlay** is only as trustworthy as the data partition: a
  file-system domain that a crafted partition compromises can rewrite the
  overlays and stores of every principal whose directory it serves, and so
  run code in those principals' supervised domains at their next start.
  No domain of the system configuration, and not the system domain, ever
  loads code from the data partition
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
  with the file. By the user's decision the partition is the vault's own,
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
  defect in littlefs can lose a key file; neither reveals a key, since
  every file is sealed under keys that storage domain never holds
  ([design-storage.md](design-storage.md#read-write-storage)).
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
  locks: the capability lock over the slots that name it, and the
  existence lock that a deletion invalidates and then waits for;
* spaces created by any holder of a budget with `SPACES`, as any holder
  of a factory creates tasks;
* a kernel stack per thread in a preemptible kernel with helping locks,
  where a call, once started, runs to its end;
* IPC gates bound to one thread, with labels, an open wait and an
  implicit reply, and messages of up to 63 words in each thread's UTCB;
* IRQ objects that hardware lines, MSIs and software trigger alike;
* the subset of the vCPU interface that delivers signals to workers;
* PCIe enumerated in user mode, as in L4Re;
* one root task that the kernel starts with the root capabilities, as
  L4's kernels start theirs.

The departures the rest of this document leans on: memory objects with
ceilings in place of a mapping database, so a fault is resolved from its
object and an access to deleted memory faults to the space's fault gate;
no pager, so every fault resolves from its object or ends the thread; a
kernel that never loads or stores through an address in a domain's memory,
taking registers, UTCB fields and memory objects, and translating umtx's
one address through the caller's page table; budgets that, as EROS's space
banks do, delete every object charged to them when they are deleted;
capabilities with generations in slots the kernel assigns; rights per
type, with pass sets; spaces with parents, and holds that keep a space's
threads from returning to user mode, for `fork`'s copy and for job
control, while every call they started runs to its end, in four named
states of which none waits for a party outside the space; groups with
grants, and no donation of time between them; consoles that are devices
like any other, driven in Erlang in the system domain, the kernel keeping
only an early console for its own log; a watchdog that
the root task pets; and a root task whose fault is a machine reset, after
a crash record, rather than a kernel panic.

**The stopgap.** A modified Fiasco, frozen at commit `50bbe8a9` with its
`bootstrap`, `sigma0`, `l4sys`, `libfdt` and `mk`, runs near-stock under
Phase 1 of the plan; `liberx`'s Fiasco backend implements the interface
over Fiasco's own calls in user mode, with nothing of erXos's kernel
semantics inside Fiasco
([design-stopgap.md](design-stopgap.md)); its call table says what is
carried in full, what with a weaker result, and what is refused.
Phase 1b of the plan carries the user-facing system further on it, behind
the same interface: domains and their connections, programs and pipes,
the web and display domains, drivers in their own domains, and networking
on QEMU `virt`. The backend's rows for them are user-mode mechanism in
L4Re's shape, every guarantee of erXos's kernel stays deferred, and the
design document of each subsystem says what it does on the stopgap.
Wherever this document says Phase 1's system, it means Phase 1 and 1b's.
The fork's kernel-mode build boots under HVF and TCG; its hypervisor build does
not boot under HVF; its null call costs 29 ns under HVF
([research](research-hierarchical-scheduling.md#fiasco-under-hvf)). Its
devices are virtio-mmio devices with ordinary interrupts, since MSIs, DMA
windows and the IOMMU are erXos's kernel's. erXos's kernel replaces it
once it runs Phase 1's system, gated on the conformance suite and
Phase 1's tests ([plan.md](plan.md)); the effort of writing it is calibrated
by a pilot first, the capability table and budgets
([design-kernel.md](design-kernel.md#risks-and-open-questions)).

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

ERTS comes as two runtime images. The BeamAsm image runs in every ordinary
domain by default, storage and network included, in user mode, with its
code in memory objects mapped writable at one address and executable at
another in spaces allowed JIT objects; ERTS's code barrier makes every
executor issue an instruction barrier before new code is reachable. The
interpreter image runs the system domain, which does bounded control only,
so no JIT object, no view that is writable before it is executable and no
C++ exists in the trusted base; deterministic mode runs the interpreter in
every domain. The roster of alternatives (interpreter only, ahead-of-time
translation on the host, an ahead-of-time image with hot-loaded code
interpreted) is kept with the triggers for re-evaluating it
([design-runtime.md](design-runtime.md#running-erlang-code-the-options)).

## Drivers and DMA

A driver is an Erlang process under a supervisor, in a domain that holds
its device's capabilities; the C under it is the device NIF's, the thin
device shim, with no parsing ([design-system.md](design-system.md#drivers)).
The domain holds the device as kernel capabilities: MMIO windows are
memory objects mapped
with device attributes, a line's IRQ object is bound to the domain's
group, and DMA is confined behind the IOMMU or declared unconfined, which
puts the domain and its device in the trusted base. Which domain holds a
device is configuration: each device goes to exactly one domain named by
the system manifest, whose creation gives it, and a device goes where its
capabilities are installed ([Decisions](#decisions),
[design-system.md](design-system.md#devices)).

The driver reaches its device through one module, `erx_device`, of BIFs and a NIF,
`liberx`'s DMA envelope exposed to Erlang
([design-runtime.md](design-runtime.md#the-device-nif)): register reads
and writes by register name through the accessors generated from the
CMSIS-SVD files, never by raw address, so the one-source rule holds;
allocation and release of buffers from a pool in a DMA-mapped memory
object the domain holds; creating queues, posting and completing
descriptors; and acknowledging an interrupt. Every device address it
gives a device is built from a memory object the domain holds, an offset
and a length, checked; the device NIF reuses a pool's addresses only
after the device's reset is done, and an unconfined device's memory is
the system domain's for the boot, never freed; and the NIF alone writes
a device address: a register the SVD
source marks as holding an address refuses a write from Erlang, and a
descriptor's address fields and addressing flags are not the driver's to
set, so no register write or ring entry can aim a device anywhere else.
Pools and queues are state of the device's record in the NIF, never of a
driver process, so a driver's crash frees nothing its device may still
hold; the NIF lets go of them only after the device's reset. The NIF
parses nothing a device wrote: Erlang does, with binary pattern matching
in a supervised process, so a malicious device corrupts no memory.
Interrupts are events in the runtime's event loop: the IRQ object is
bound to the domain's group, the poll backend delivers it to the owning
Erlang process as a message, and the process acknowledges through the
NIF; no dirty scheduler blocks in an interrupt wait. Every delivery, a
doorbell's ring or a device's interrupt, is a hint to look and never an
event in itself: its sink reads the ring or the device's status, so a
late, repeated or stray delivery costs one look. The NIF copies a
received buffer's bytes into a fresh binary at completion and returns the
buffer to its pool, so no binary aliases memory a device can write, and
transmit copies into the pool; both copies are per-byte C.

Every piece of native driver code other than the device NIF is a native
shim, a row of the driver table, a stopgap or third-party shim such as a
ported sDDF driver included, and without the row none runs
([design-system.md](design-system.md#the-driver-table)). A native shim
runs as a sub-space port of the driver's domain, exactly as a program is
a port of its session, holding the device's capabilities and a channel to
its owner, so for a confined device its bugs cannot touch the Erlang
heap; for an unconfined device it is in the trusted base, as the device
is. A native driver exists only where gate G9's measurement shows that an
Erlang driver misses the device's timing or costs more than a stated
fraction of its throughput, and its row carries the measurement. The
costs to state: interrupt-to-handler latency passes through the runtime's
scheduler, so G9 decides batching per device class; and one ERTS instance
per driver domain is why devices are grouped by configuration.

On QEMU `virt` the IOMMU translates only PCIe devices, so confined drivers
use virtio-pci and its MSIs; virtio-mmio drivers are unconfined. The first
drivers are virtio console, block and network, written after sDDF's model
of the split between a driver, which touches registers and rings and
parses nothing from clients, and the policy beside it; sDDF is the oracle
for their behaviour and throughput, and nothing of it is imported
([Dependencies](#dependencies)). The PCIe enumerator is an Erlang process
in the PCIe domain, which holds the configuration window and nothing
else: it parses configuration space in Erlang with a fuzz target, and
programs MSIs and bus mastering at the device service's request, at a
function's first start and again after each reset its driver reports,
which puts the PCIe domain whole in the trusted base. The console's UART
belongs to the console driver in the system domain, so what the operator
types reaches only the system domain and the session connected to the
console, and the host link's UART
is the system domain's on every platform, beside the host link service.
The system manifest names both UARTs by device-tree path; the manifest
check proves the console's unit is the system domain's, and at boot the
device service refuses a manifest whose console path is not the one
`/chosen/stdout-path` names. Of the consoles the kernel keeps only an
early console, the UART whose kind and address the platform's kernel
build fixes, written by polling from the first step of boot and at a
panic or the machine's end; the boot stops, with a message on that UART,
when `stdout-path` names another
([design-kernel.md](design-kernel.md#console-log-and-panic)). Beside it
the kernel keeps the devices of `hw/kernel_devices.txt`. Release builds
give a domain an unconfined device, one without an IOMMU stream, only
when the system manifest names it, because a bus master's registers
alone can aim its DMA anywhere, and give each such device a domain of
its own.

## Storage and networking

Storage and networking are services in Erlang domains of their own, with
the block and network drivers as supervised processes of the same
domains, reached through facets like every other service, so a file
system or a network stack that fails, or
is attacked through its medium or its packets, fails within its domain,
and inside it within the process that met the input. The medium's
layout and formats, the storage services and system updates are
[design-storage.md](design-storage.md). The network service's choices
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
one segment size, and a segment is a run of one
([design-network-fastpath.md](design-network-fastpath.md)). Output emits
runs, and the copy each medium needs anyway cuts a run into frames,
writing the header values Erlang chose and the checksums as it copies,
so the frames are byte for byte those per-segment output would send.
The interface merges each batch of received frames before it classifies
them, with one C call that groups in-order segments of one flow by the
rule of FreeBSD's large receive offload, and hands the connection one
segment for each group. Every TCP decision stays in Erlang, and what is
left for a single segment, the unit of request-reply traffic, is a lean
step over a small control block.

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
and `struct cc_algo`, so RACK-TLP and BBR, which the owner deferred, come
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
bulk transfer, is first measured on QEMU on the stopgap, as a baseline
that decides nothing, since every interrupt and doorbell there passes the
stopgap's one service thread; the same measurements on erXos's kernel
decide, and the Raspberry Pi 4 confirms or reopens the decision (gates
GN-QEMU, GK3 and GN-board of [plan.md](plan.md#decision-gates)). At 1 Gb/s
a full-size Ethernet frame takes 1,538 bytes of wire time with its
preamble and inter-frame gap, so line rate is 81,274 frames a second each
way, 12.3 us a frame (computed from IEEE 802.3's framing). If the stack
cannot keep up, only the pure function of TCP's core that the
measurement names moves to native code, behind the same signature and
the same process interface, as a measured exception, and everything else
stays Erlang.

The gates also offer minimum-size frames, about 1.49 million per second at
1 Gb/s including framing, and invalid traffic, connection and reassembly
floods. The network domain runs on its own grant. Traffic that names no
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
| Read-write storage: the F2FS on-disk format, and littlefs's, its stopgap | the superblock's feature bits | [design-storage.md](design-storage.md#data-model) | erXos's F2FS, which refuses features it does not implement, the encryption, compression and atomic-write feature flags among them |
| Removable media and exchange: FAT12, FAT16 and FAT32 with long names | FAT32's file-system version, 0.0 | [design-storage.md](design-storage.md#removable-media-fat) | the FAT server, which refuses another version |
| Slot images and update manifests | 1 | [design-storage.md](design-storage.md#system-updates) | the update service, after the manifest's signature, which a development build checks against the development key it embeds |
| The vault's files: a principal's keys and credential slots, and the machine's file | 1 | [design-system.md](design-system.md#the-vault) | the vault's file decoder, bounded and fuzzed, then the slots' authenticated encryption |
| TPM 2.0 responses | the TPM 2.0 library specification's | [design-system.md](design-system.md#the-vault) | the vault's TPM client's response decoder, bounded and fuzzed, then the session's HMAC |
| The boot-selection record: the firmware's `autoboot.txt` on the Raspberry Pi, the same file read by the harness on QEMU; with the firmware's one-shot trial request, two states, `normal(C)` and `trial(S)` | the firmware's | [design-storage.md](design-storage.md#system-updates) | the slot writer, which rewrites it only from one of its two encodings, one per committed slot |
| Host-link frames and sessions, with stream 4 carrying files, one 9P2000.L message per frame within an `msize` of 4,096 | 2 | [design-live.md](design-live.md#host-link-frames) | the deframer and the host grammar; another version is refused |
| The file protocol: 9P2000.L's operations, as terms in frames on connections inside the machine, and as 9P2000.L bytes at the edges, the host link's files stream, QEMU's virtio-9p and the network | 9P2000.L, agreed by its `version` operation; the frame profile is part of the ABI's version | [design-files.md](design-files.md#the-file-protocol) | inside the machine, the funnel's grammar, then `erx_fs` and `liberx`'s client, both generated from the profile; at the edges, the generated codec `erx_9p`, bounded by `msize` and fuzzed |
| A program's startup message and the channel protocol between a program and its handler | 1 | [design-programs.md](design-programs.md#the-channel) | `liberx`'s channel decoder, before `main` and at every reply; the handler's decoder, bounded, in the session |
| Code blobs, manifests and overlays | manifests and overlays 1; a blob is its bytes, named by their SHA-256 | [design-live.md](design-live.md#the-code-store) | the code server's hash check; manifests and overlays by the code service's decoder |
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
  core/           the functional core shared with the stopgap: scheduler,
                  park and defer machines, budgets, mapping plans, decoders,
                  the boot-image validator, the entropy generator
  crypto/         imported C primitives as erXos's code, a directory per
                  upstream directory, each with an ORIGIN.md: FreeBSD's
                  SHA-256 (sha2/) and ChaCha20 (chacha20/), and BLAKE3's
                  portable C (blake3/); the cores' archive builds them
  arch/<arch>/    the architecture layer, a directory per architecture
  platform/       the platform layer: device-tree discovery and the
                  devices the kernel drives
fiasco/           the stopgap: Fiasco, bootstrap, sigma0, l4sys, libfdt and
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
                  services (erXos's F2FS, the FAT server, the slot writer)
                  and the network stack (erx_net, with NOTICE-freebsd)
toybox/           toybox 0.8.15 and wak as erXos's code (toybox/ORIGIN.md)
storage/          littlefs's NIF glue, C17, a stopgap
tools/            Ruby: erx (build, pack, qemu, bench, console, inspect,
                  watch), generators, the stack, chokepoint and manifest
                  checks, test runners
specs/tla/        TLA+/PlusCal models, configurations, expectations and
                  invariant-to-implementation mappings
test/             conformance, transcript, oracle, hosted and fuzz tests
bench/            benchmarks and recorded results
docs/             design, plan, research records, style
```

## Build and toolchain

The development host is macOS on Apple Silicon. Tools, installed through
Homebrew or built from pinned sources: LLVM's clang and `lld` (the latter
a separate formula) for erXos's own code and the runtimes; the GNU cross
toolchain `aarch64-elf-gcc` and binutils (FreeBSD's port names them
`aarch64-none-elf-`, and the build takes either prefix), GNU make 4.4.1 and
Perl for the stopgap Fiasco, as L4Re's macOS guide prescribes
([research](research-hierarchical-scheduling.md#fiasco-under-hvf)); Ruby;
QEMU 11.1; `dtc`; CBMC, at the version `test/cbmc/roster.json` pins, for `make check-cbmc`; `b3sum`, the oracle the imported BLAKE3 is compared with;
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
into its own directory under `build/third_party/`; it also pulls the oracle's
pinned OCI toolchain image by manifest digest. Every other target runs
offline. The top-level `Makefile` builds the kernel or the stopgap
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
| Conformance | every kernel call's contract, run identically on both kernels for every call the stopgap carries | QEMU, HVF |
| Transcript tests | boot, shell sessions, domain lifecycle, connections taken down, driver restarts, a watchdog reset, scripted through the console and the host link | QEMU, HVF, with one boot smoke test under TCG; a test that passes under only one accelerator is a bug until explained |
| The oracle | OTP's suites in a test domain against stock OTP in the isolated Linux oracle; `libc-test` (`make check-oracle`) | QEMU and a Linux container on the development host |
| Deterministic mode | `erx.det=1`: one CPU, TCG with instruction counting, the interpreter; byte-identical transcripts | QEMU, TCG |
| Differential tests | the funnel against `binary_to_term/1`; float conversion against the host; cross-domain behaviour against two connected stock nodes; erXos's kernel against the stopgap; each recombined ERTS part against its predecessor; erXos's F2FS against Linux's in a QEMU guest and against littlefs; the EROFS reader, on images fsimg writes, and the FAT server, on images fsimg creates and by fsimg's verify of the images it writes; the network stack against FreeBSD's on the FreeBSD test host and against Linux's, by interoperation and scripted packet tests; each per-byte primitive against its reference on the host; the command shell against plan9port's rc, and its commands named like FreeBSD utilities against FreeBSD 15.1's in the oracle guest | host and QEMU |
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
native numbers.

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

| Component | Purpose | Licence | Status | How it enters |
| --- | --- | --- | --- | --- |
| Erlang/OTP 29.1.2 (ERTS and the shipped applications) | the runtime and the system's Erlang code | Apache-2.0 | permanent | imported into `otp/` as erXos's code, with an origin file |
| OTP 29.1.2 Common Test controller reporting copy | exact case, group-instance and completed-job records for the host oracle | Apache-2.0 | permanent development dependency, never in a production image | modified `test_server_ctrl.erl` in `test/oracle/common_test/`, with original and modified hashes and an origin file; runtime, library and testcase sources remain stock ([design-build.md](design-build.md#oracle-and-protocol-models)) |
| Third-party code inside OTP's tree: asmjit, PCRE2, zlib, zstd, Ryu | the JIT's assembler, in the BeamAsm image alone, `re`, the `zlib` and `zstd` modules, shortest float printing | asmjit Zlib; PCRE2 BSD-3-Clause WITH PCRE2-exception; zlib Zlib; zstd BSD-3-Clause (or GPL-2.0-only, used under BSD); Ryu Apache-2.0 or BSL-1.0 | permanent; asmjit only in the BeamAsm image, never in the system domain's | part of `otp/` |
| musl 1.2.6 | the C library of every runtime and native program | MIT, with the BSD and public-domain parts listed in [research](research-c-library.md#musl-126) | permanent | imported into `musl/` as erXos's code, with an origin file |
| Fiasco `50bbe8a9`, `bootstrap` `a4f4ad18`, `sigma0` and `l4sys` from `l4re-core` `e2e2d5af`, `mk` `22cc26e5` | the stopgap kernel behind erXos's interface | MIT, as each project's `LICENSE.spdx` declares for its main package, but carrying GPL-2.0 code in every build, in files whose own notices override that declaration and which `LICENSE.spdx` does not list: `src/kern/kobject_rpc.h`, which the kernel's task, IPC gate and IRQ code include, and, in development builds, the kernel debugger's `jdb_object.cpp`; the debugger's disassembler, capstone, is BSD-3-Clause-Attribution; Fiasco's GPL-licensed `src/lib/regex`, `simple_malloc` and `gcov`, the LGPL `perfctr` code and the Qualcomm board support, which also carries GPL-2.0 files, are excluded; the link closure of `bootstrap` and `sigma0` recorded at import | **stopgap**, replaced by erXos's kernel ([plan.md](plan.md)); since every build carries GPL code, any distribution outside the project, in source or binary form, waits for the replacement, as CLAUDE.md's rule for stopgaps under a license that is not permissive requires, with one exception: the website's demo image is distributed with its source offered, a link beside the console to the erXos release tag or commit it was built from ([site/README.md](../site/README.md)) | imported into `fiasco/` as erXos's code, with origin files |
| `libgcc` from `l4re-core` `e2e2d5af` | the 128-bit float helpers that musl's `long double` makes the root link | GPL-3.0-only WITH GCC-exception-3.1, as `fiasco/l4re-core/LICENSE.spdx` concludes | stopgap |
| Code translated from Fiasco into erXos's kernel | the kernel's design and know-how | MIT, notice kept per file and in `kernel/NOTICE-fiasco`; translated or copied only from files whose effective licence is permissive: the licence Fiasco's `LICENSE.spdx` declares for the file's package, MIT for the kernel, unless the file's own notice says otherwise, checked against the file's upstream history, which the import records; the GPL-2.0 files `kobject_rpc.h` and `jdb_object.cpp` are needed by nothing erXos's kernel does, since its dispatch is generated from the ABI file and it has no kernel debugger (provisional, for the user to confirm) | permanent | written in `kernel/` |
| libfdt `5756062b` | device-tree parsing in the kernel and the stopgap | BSD-2-Clause (dual GPL-2.0-or-later) | permanent | imported with the stopgap; kept by erXos's kernel |
| Plan 9's `libmemdraw`, from 9front | the per-byte pixel primitives of `erx_memdraw`; its image(6) loader `cloadmemimage` is linked into no release, since the `Y` decoder is the Erlang `erx_draw_image` ([design-display.md](design-display.md#dependencies)) | MIT (9front's `lib/legal/NOTICE`) | permanent | 9front at commit 2859ae04, imported as erXos's code into `display/libmemdraw`, with an `ORIGIN.md` |
| plan9port's `libdraw`, acme, sam and 9term | draw clients, and oracles of the draw protocol's compatibility | MIT, confirmed at import | permanent | ported as erXos's code, the connection code replaced |
| LVGL 9 | the native widget renderer for panels, behind `erx_ui_renderer` | MIT | stopgap, retired by the Erlang renderer once it passes the parity test and matches LVGL's frame times on a 240x240 panel ([plan.md](plan.md#decision-gates), GD) | 9.6.0, the git submodule `display/lvgl/lvgl` from erXos's fork `https://github.com/stass/lvgl`, pinned by the commit the tree records ([ORIGIN.md](../display/lvgl/ORIGIN.md)), its patches commits on a branch of the fork; built out of tree as the native program `erx-lvgl` (`display/lvgl/`, `tools/erx build lvgl`) |
| React and React DOM 19.3.1, with their `scheduler`, and their type definitions (`@types/react`, `@types/react-dom`, `csstype`), used only by the type check | the web client's rendering ([design-web.md](design-web.md#dependencies)) | MIT | permanent, in the client's files in the web domain's release | fetched by pnpm at the versions and integrity hashes of `web/pnpm-lock.yaml`, installed with install scripts off |
| TypeScript 7 (7.0.2), its native compiler | the web client's language and type check (`tsc --noEmit`) | Apache-2.0 | permanent host tool, never part of an image | a native binary in a per-platform package, pinned with its integrity hash by `web/pnpm-lock.yaml`, fetched by `tools/erx fetch`, installed; run as a subprocess |
| esbuild 0.28 (0.28.2) | bundling the web client | MIT | permanent host tool, never part of an image | a native binary in a per-platform package, pinned with its integrity hash by `web/pnpm-lock.yaml`, fetched by `tools/erx fetch`, installed with its install script not run; run as a subprocess |
| Playwright 1.65.0 (`@playwright/test`, `playwright`, `playwright-core`), with its Chrome Headless Shell 158.0.8127.18 for macOS on arm64 | the web client's browser tests | Apache-2.0; Chromium BSD-3-Clause with its third-party notices | test tool, never part of an image | pinned by `web/pnpm-lock.yaml`; the Chromium is a `zip` source of `deps.lock` with its SHA-256, fetched by `tools/erx fetch` only on the host it names; run as a subprocess |
| `@types/node` 26.6.6, with `undici-types` | the type check of the web client's tests | MIT | test tool, never part of an image | fetched by pnpm at the versions and integrity hashes of `web/pnpm-lock.yaml` |
| cowboy 2, with cowlib and ranch | the web domain's HTTP, WebSocket and TLS acceptance ([design-web.md](design-web.md#the-network-front-end)) | ISC | permanent | fetched at a pinned version and hash and built out of tree against erXos's OTP, or imported as erXos's code if changed |
| plan9port's `fixed` fonts as Plan 9 subfonts | the terminal emulator's and the Erlang renderer's glyphs | public domain | permanent | imported with an origin file |
| BLAKE3 1.8.7, the official C implementation (the `c/` directory of `BLAKE3-team/BLAKE3`) | the boot image's index and file hashes and the entropy generator's mixing: its portable code in the kernel and `bootstrap`, its SIMD code in the host tools ([design-kernel.md](design-kernel.md#the-boot-image)) | CC0-1.0, Apache-2.0 or Apache-2.0 WITH LLVM-exception, used under Apache-2.0 WITH LLVM-exception | permanent | imported into `kernel/crypto/blake3/` as erXos's code, portable files only, with the official test vectors and an origin file; the kernel's and `bootstrap`'s builds take its portable C alone |
| FreeBSD's SHA-256 (`sys/crypto/sha2/sha256c.c`, `sha256.h`) and ChaCha20 (`sys/crypto/chacha20/chacha.c`, `chacha.h`) at `release/15.1.0-p6` (`95719d8a`) | the entropy generator's ChaCha20, and the C SHA-256 of the per-byte primitives | SHA-256 BSD-2-Clause (Colin Percival); ChaCha20 public domain (D. J. Bernstein, via OpenBSD); erXos's changes BSD-2-Clause | permanent | imported into `kernel/crypto/sha2/` and `kernel/crypto/chacha20/` as erXos's code, each directory with an origin file recording each file's SHA-256 |
| `drivers-frst` `6459d70997da1a2ad97775c8772b4a41284b0a9e`, PL011 UART subset | `bootstrap`'s console during the stopgap boot | MIT, from its package `LICENSE.spdx` and each retained file's notice | **stopgap**, replaced with the stopgap boot path | only the PL011 source and its required headers and build support are imported into `fiasco/`, with their own origin inventory; other drivers are excluded |
| Raspberry Pi Pico SDK 1.5.1, `src/rp2040/hardware_regs/rp2040.svd`, UART0 peripheral only | the PL011's register layout (`hw/svd/pl011/pl011.svd`), from which the generator makes the accessors and `erx_device`'s table | BSD-3-Clause, Copyright (c) 2020 Raspberry Pi (Trading) Ltd., kept in the file | permanent | imported as erXos's code with an origin file that lists the edits; `tools/carve_pl011_svd.rb` makes it from the pinned upstream file |
| Arm's machine-readable architecture specification (BSD package) | the source of the facts in the AArch64 port's `hw/sysreg/aarch64.json` | BSD-3-Clause | permanent, as a pinned refresh input | fetched with a pinned SHA-256 and read only by `tools/erx sysreg refresh`; only the extracted file is checked in, with its `ORIGIN.md` and Arm's `LICENSE.md` |
| LLVM libc++, libc++abi, compiler-rt builtins 23.1.x | BeamAsm's C++ runtime, in the BeamAsm image alone, never in the system domain's; compiler support routines | Apache-2.0 WITH LLVM-exception | permanent | fetched and built out of tree |
| sDDF (0.7.0) | the model for the split between a driver, which touches registers and rings and parses nothing from clients, and the policy beside it; the oracle for the virtio drivers' behaviour and throughput | BSD-2-Clause | reference: model and oracle, nothing imported. If a board's driver proves hard, one of its drivers may run as a stopgap native shim in a sub-space port, imported as erXos's code with an origin file, a row of the driver table and a `TODO.md` item, and replaced by the Erlang driver behind the same interface; erXos keeps its own lane layout, a producer ring and a consumer reader page, which is stricter than sDDF's shared queue region | read, never fetched into a build |
| FreeBSD's source at commit `975e3605ebb1` of 16.0-CURRENT (`main-n285245`), and at `release/15.1.0-p6` (`95719d8a`), the tree the translation was read from: `sys/netinet`, `sys/netinet6`, `sys/net` and `sys/netinet/cc` | the decisions erXos's TCP/IP stack translates into Erlang, with the changes between the two that the wire can see and the real bug fixes ported, and the inline CUBIC arithmetic of `cc_cubic.h` compiled on the host as the CUBIC test's oracle ([design-network-stack.md](design-network-stack.md#provenance-and-notices)) | BSD-2-Clause and BSD-3-Clause, confirmed per file at the pin; `in_cksum.c` (BSD-4-Clause) and the unlicensed `tcp_stacks/tailq_hash.*` are never translated | permanent: the Erlang translation is erXos's code in `erlang/apps/erx_net/` and keeps FreeBSD's notices per module and in `NOTICE-freebsd`; the source is a reference, never in an image | fetched at each pinned commit and verified against a pinned SHA-256, out of the tree |
| FreeBSD's source at `release/15.1.0-p6` (`95719d8a`): `share/termcap/termcap` | the `xterm` and `vt100` entries that erXos's `abi/termcap` restricts to what its terminal emulator implements ([design-display.md](design-display.md#term-and-termcap)) | its BSD licence, confirmed at the pin | permanent: a reference, never in an image | fetched at the pinned release and verified against a pinned SHA-256, out of the tree |
| FreeBSD's source at `release/15.1.0-p6` (`95719d8a`): `sys/sys/signal.h` | the oracle of the signal table's names and numbers in `abi/signals.txt`, which `test/host/abi_signals_test.rb` compares with it ([design-programs.md](design-programs.md#signal-numbers)) | BSD-3-Clause | test data, never in an image | fetched at the pinned commit (deps.lock's `freebsd-signal`) and verified against a pinned SHA-256, out of the tree |
| FreeBSD's TCP test suite, `freebsd-net/tcp-testsuite` | packetdrill scripts run on the FreeBSD test host and against erXos's stack, whose verdicts must agree | BSD-3-Clause | test data, never in an image | fetched at a pinned commit and SHA-256, out of the tree |
| packetdrill, nplab's version, which the test suite names | runs the test suite's scripts on the FreeBSD test host; erXos's own runner reads the scripts on erXos and holds no code of packetdrill's | GPL-2.0 | test tool, built and run only on the FreeBSD test host, never linked to anything of erXos's and never in the tree or an image | fetched at a pinned commit and SHA-256 by the fetch step, built on the test host |
| The FreeBSD test host: FreeBSD 16.0-CURRENT on x86-64, its vnet jails `erxpeer0` to `erxpeer3` and tap devices on one bridge | the network stack's oracle: FreeBSD's own stack, for the packet scripts' verdicts, the host runs through the tap transport and the traffic tests ([design-network-stack.md](design-network-stack.md#verification)) | BSD-2-Clause for FreeBSD's base, with the licences of the third-party code it contains | test machine, never in an image erXos ships | outside the tree: each verdict record names the kernel it ran on and lives in the history repository |
| lwIP 2.2.1, with lwip-contrib 2.1.0's `tapif` port, and over netmap a small `netif` against `NIOCCTRL` kept outside the tree | the network stack's performance baseline: a C stack over the same medium, a tap or a VALE switch, for the bulk and request-reply benchmarks ([design-network-fastpath.md](design-network-fastpath.md#benchmarks-and-targets), [design-network-stack.md](design-network-stack.md#the-netmap-transport)) | BSD-3-Clause | benchmark tool, never in an image | fetched at a pinned release and SHA-256 and built out of the tree on the FreeBSD test host |
| FreeBSD 15.1 QEMU image | the command shell's oracle guest, for its commands named like FreeBSD utilities ([design-shell.md](design-shell.md)) | BSD-2-Clause for FreeBSD's base, with the licences of the third-party code it contains | test tool, never in an image erXos ships | fetched at a pinned release and SHA-256, run under QEMU on the development host |
| `msantos/pkt` | an independent packet decoder, the fuzz targets' differential oracle for the stack's codecs | BSD-3-Clause | test tool, never in an image | fetched at a pinned commit and SHA-256, compiled out of the tree on the host's stock OTP |
| fsimg, commit `a87ab69f` of https://github.com/stass/fsimg | writes every EROFS image erXos makes, verifies it, and is the oracle of the FAT server: it creates FAT images for the server to read and checks the images the server writes | BSD-2-Clause | **permanent** | fetched at a pinned commit and SHA-256 by the fetch step, built for the host out of tree by `tools/erx build fsimg`, a step of `make setup`; run as a subprocess by argument vector, never linked and never part of an image |
| littlefs 2.11.3 | the read-write file system of the data partition and of the vault's partition until erXos's F2FS replaces it, as a NIF of the storage domains' Erlang release | BSD-3-Clause | **stopgap**, replaced by erXos's F2FS, in Erlang, at an installation that creates both partitions afresh | imported into `littlefs/` as erXos's code, its four source files and licence only, with an origin file |
| OpenSSL 3.5 | OTP's `crypto`, `ssl` and `ssh`, in application domains and the vault's, never in the system domain; the vault's Argon2id (`ARGON2ID`, in OpenSSL since 3.2), HKDF and AES-256-GCM | Apache-2.0 | permanent; a long-term-support series, supported until 2030-04-08 ([research](research-boards-storage.md#cryptography-libraries)) | fetched at a pinned release and hash and built out of tree against erXos's C library, or imported as erXos's code if changed |
| toybox 0.8.15, with Ray Gardner's `wak` as its awk | the UNIX commands of the command shell and of programs | 0BSD | permanent | imported into `toybox/` as erXos's code, with an origin file; built as one multicall program over the POSIX-lite personality, its Linux-specific applets left out ([research](research-boards-storage.md#the-toolbox)) |
| Monocypher with its optional Ed25519 code, the candidate for the small verifier, which the roadmap's security closure confirms and pins ([plan.md](plan.md#m11-security-closure)) | the update service's check of an update's signature | BSD-2-Clause OR CC0-1.0, used under BSD-2-Clause ([research](research-boards-storage.md#cryptography-libraries)) | permanent | fetched at a pinned version and hash and built out of tree |
| bitcoin-core/ctaes, a small standalone constant-time AES | full-width AES-128 permutation for runtime reference identities (`erx_ref_permute`), without linking OpenSSL into the system domain | MIT | permanent | imported into `ctaes/` as erXos's code at a pinned commit, reviewed for constant time, with an origin file; FIPS 197 vectors and agreement with OpenSSL in `test/host/erx_ref_test.rb`; a hardware path must agree with it |
| Raspberry Pi firmware | starts the boards and loads the kernel and the boot image | Broadcom's binary licence: unmodified, for Raspberry Pi devices only, its notice kept ([research](research-boards-storage.md#the-raspberry-pi-firmware-licence)) | permanent, board-specific | fetched at a pinned version and copied unmodified into images for the boards |
| Raspberry Pi `usbboot`, its `secure-boot-recovery` and `secure-boot-recovery5` images | an installation's secure boot on a board: flashing the secure-boot bootloader and writing the hash of the owner's key into OTP; the packer itself signs each slot's `boot.img` ([design-platforms.md](design-platforms.md#trust-in-the-boot)) | Apache-2.0 for its source, Raspberry Pi's firmware licence for the binaries it carries | permanent; a tool the board's owner runs, never part of an image | fetched at a pinned commit and hash by the installation's tooling, run on the owner's host |
| TF-A 2.15.0's BL31 for the Raspberry Pi 4 | the firmware calls that start CPUs and end the machine on the Pi 4, loaded as its boot stub ([design-platforms.md](design-platforms.md#firmware)) | BSD-3-Clause | permanent, board-specific | fetched at a pinned version and hash, built out of tree, and copied into images for the Pi 4 |
| The boards' device trees, built from Linux's sources | describe each board to the kernel | Pi 4 GPL-2.0; Pi 5 GPL-2.0 OR MIT, which the import confirms for every file it includes | permanent, board-specific. The Pi 4's tree is a permanent copyleft dependency, which the user agreed to. It is compiled unmodified and ships as a file of its own in each slot's boot partition, with its source beside it, and nothing links it to erXos's code | fetched at a pinned version and compiled with `dtc` |
| Host tools: LLVM clang and lld (release images are built with exactly 23.1.3 and their hashes published, so a rebuild can be compared), LLVM's binary tools, `aarch64-elf-gcc` and binutils (stopgap only), GNU make, QEMU 11.1, `dtc`, Ruby with REXML, Perl, Node.js and pnpm for the web client at least at the versions `web/package.json` records (Node.js 24.2, pnpm 12.18), GNU coreutils, git, host OTP 29.1.2, `b3sum` (BLAKE3's Rust implementation, the differential oracle of the imported C), herdtools7's `herd7` (CeCILL-B, with Arm's ASL library under BSD-3-Clause) for the weak-memory litmus tests, with OCaml, dune, menhir and zarith, which build it; Autoconf, Automake and Libtool, which build fsimg for the host; for the F2FS oracle, a Linux guest built from Debian 13 packages that `deps.lock` pins: a kernel with F2FS (Debian's generic arm64 kernel is the candidate), a userland and f2fs-tools | building, running and testing | various; the guest's kernel and tools under GPL licences | tools, never part of an image | installed through Homebrew on macOS, built from the pinned tarball for the host OTP and for herd7 (herdtools7 7.58, which `deps.lock` pins, built out of tree into `build/herdtools7` by `tools/erx build herd7` with dune alone: opam, herdtools7's Makefile and its scripts never run, and a new pin's dune actions on herd7's build path are reviewed before it lands), or fetched from snapshot.debian.org at a pinned version and hash for the guest; invoked as subprocesses, never linked |
| TLA+ tools (TLC and the optional PlusCal translator) | independent protocol models and counterexample traces | MIT for the tools; packaged dependencies reviewed at the tool pin | permanent host tool, never part of an image | jar the explicit fetch step supplies, verified against a pinned version and SHA-256; `TLA_TOOLS_JAR` selects its path; a Homebrew JVM runs it as a subprocess ([design-verification.md](design-verification.md#model-suite-and-runner)) |
| Docker-compatible Linux engine and the oracle's OCI toolchain image; OrbStack as the local macOS provider | isolated stock OTP builds and full suite execution | Docker/Moby Apache-2.0; OrbStack under its vendor licence; the toolchain image's package licences recorded with its pin | permanent development tools, never part of an erXos image | installed local engine invoked through an explicitly selected context; toolchain image fetched only by manifest digest and platform from `deps.lock`, with no package installation during builds or tests ([design-host-oracle.md](design-host-oracle.md)) |
| CBMC | evaluate bounded checking of the actual C17 budget and capability cores | BSD-4-Clause for CBMC; solver dependencies reviewed at the tool pin | permanent host tool if the pilot is adopted, never part of an image | Homebrew installation, its version pinned in `test/cbmc/roster.json` and its identity and options recorded in each report; invoked as a subprocess; adoption gate in [plan.md](plan.md#verification-work) |
| awklog | evaluate relational manifest and authority checks | BSD-2-Clause | permanent host tool if the pilot is adopted, never part of an image | unmodified source fetched from `stass/awklog` at a pinned commit and SHA-256, run as a subprocess through host awk; adoption gate in [plan.md](plan.md#verification-work) |
| libvterm 0.3.3 | the differential oracle of the terminal emulator core `erx_vt` ([design-display.md](design-display.md#the-oracle)) | MIT | test tool, never part of an image and never linked into erXos | fetched at its pinned release and SHA-256 and built out of tree for the host with erXos's harness `test/vt/vterm_dump.c`, its `unicode.c` replaced by width functions from `include/erx/vt_width.h`, generated from `erx_vt`'s width table |
| `vttest`, Thomas Dickey's | the corpus's recordings of `vttest`'s core screens for the terminal emulator | MIT-style (X11), confirmed at the pin | test tool, never part of an image | fetched at a pinned release and SHA-256, built out of tree for the host and run on a host pseudo-terminal by a Ruby driver |
| musl's `libc-test` | the C library's oracle | MIT | test tool, never part of a shipped image; its programs run only in test images | fetched at a pinned commit, whose exported tar a pinned SHA-256 holds, since its host serves no stable archive; built out of tree against erXos's musl |
| The 9front build: 9front's `libmemdraw` and the parts of its `libdraw` it links, unmodified | the display's oracle of shape pixels, of every `erx_memdraw` operation against the code it was imported from, and through `cloadmemimage` of the Erlang `Y` decoder ([design-display.md](design-display.md#verification-and-testing)) | MIT | test tool, never part of a shipped image | fetched at the commit the import's origin file records and verified against a pinned SHA-256; built for the host out of tree by erXos's own compiler invocations against plan9port's `lib9`; 9front's mkfiles never run |
| Test tools: plan9port's rc, the command shell's oracle; the Open POSIX Test Suite, the POSIX-lite personality's oracle; swtpm 0.10 with libtpms, the TPM 2.0 that QEMU attaches as `tpm-tis-device` for the vault's `tpm` backend | testing | rc MIT; the Open POSIX Test Suite BSD-2-Clause and GPL-2.0-or-later; swtpm BSD-3-Clause; libtpms BSD-3-Clause, with the TCG reference code under the TCG's BSD licence | tools, never part of a shipped image; the suite runs only in test images | fetched at a pinned commit or release and hash and built out of tree: rc for the host, since Homebrew has no package for it ([research](research-boards-storage.md#the-command-shells-oracle)), from plan9port's `deps.lock` pin by erXos's own compiler invocations (only rc and the lib9 members it links; plan9port's build scripts never run), the suite against erXos's musl; swtpm installed through Homebrew and run beside QEMU as a subprocess |
| v64 `87d26deb` | the website's in-browser console: an AArch64 virt machine in WebAssembly that boots the erXos image in a visitor's browser | BSD-2-Clause and MIT | permanent, website only, never in an image | unmodified source fetched at a pinned commit through `deps.lock` and built by `tools/build_site.rb`, whose `npm ci` alone fetches online (an exception for the site build); built in a staged copy of the fetched tree, with npm install scripts disabled; the built bundle and core ship with the site beside v64's licence texts and the notices of the third-party code compiled into them (Berkeley SoftFloat, zstd and the Rust standard library), which the build collects and checks ([site/README.md](../site/README.md)) |
| Closure Compiler v20210601 | builds v64's JavaScript bundle | Apache-2.0 | permanent host tool for the website build | unmodified jar fetched through `deps.lock` |
| xterm.js 5.5.0 and its fit addon 0.10.0 | the website console's terminal | MIT | permanent, website only | loaded by the visitor's browser from jsDelivr at pinned versions, checked by Subresource Integrity |

### Licences and notices

erXos's own code is under the [BSD 2-Clause licence](../LICENSE), copyright
Stanislav Sedov <stas@deglitch.com>. Code translated from Fiasco keeps its MIT
notice, per file and in `kernel/NOTICE-fiasco`, and comes only from files
whose effective licence is permissive, judged by Fiasco's `LICENSE.spdx`,
the file's own notice and its upstream history, never by a header alone:
most of Fiasco's kernel sources carry no notice and take the MIT that
`LICENSE.spdx` declares for the kernel package, 751 of the 789 C++
sources and headers under `src/kern` at `50bbe8a9` (counted 2026-10-31),
while a file's own notice can say otherwise, as `kobject_rpc.h`'s does.
GPL-2.0 counts a translation as a modification, so nothing is translated
from a file under the GPL, or from one whose history shows code taken
from such a file. Code translated from FreeBSD's network stack keeps the
BSD notices of every file it derives from, per Erlang module and in
`erlang/apps/erx_net/NOTICE-freebsd`, and nothing is translated from
`netinet/in_cksum.c`, whose four-clause licence keeps the advertising
clause, or from `tcp_stacks/tailq_hash.c` and `.h`, which carry no
licence ([design-network-stack.md](design-network-stack.md#provenance-and-notices)).
Every imported tree keeps its licence files. Two
mechanisms carry the conditions of the third-party licences, and both
hold by construction:

* **Changed files say so.** Apache-2.0, OTP's licence, and the Zlib
  licence of asmjit and zlib require a changed file to carry a notice of
  the change. Each import's `ORIGIN.md` records the SHA-256 of every file
  as imported. A build check fails when a file under a directory that
  holds an `ORIGIN.md`, as every import does, differs from its recorded
  hash without erXos's change notice in its header comment, or is absent
  from the record without erXos's own notice; a changed file that cannot
  hold a comment, such as a regenerated bootstrap `.beam`, is named in its
  tree's `ORIGIN.md` instead. The set of changed files is derived from the
  record, so nobody keeps a list of them, and the rule covers every
  imported tree whatever its licence, so no list of licences decides where
  it applies.
* **Unknown provenance fails the build, and every image carries the
  notices of what it holds.** Every file that goes into an image has
  recorded provenance: a file erXos writes carries
  `SPDX-License-Identifier: BSD-2-Clause`; a file of an
  imported tree is under its tree's `ORIGIN.md`; a fetched artifact has
  its `deps.lock` entry; a generated file takes the provenance of the
  inputs its build rule records. Each file's licence is recorded with its
  provenance: an imported file's entry in its `ORIGIN.md` holds the SPDX
  identifier of its header or, for a file without one, the licence its
  tree's manifest declares for its package, such as Fiasco's
  `LICENSE.spdx`, or the licence the import's review assigned, marked as
  reviewed; a fetched artifact's
  licence is in its `deps.lock` entry. The packer takes each image's
  closure from the linker's map of every object and archive each
  executable links, the compiler's dependency files of each object, and
  its own list of every other file it packs (BEAM and application files,
  data, device-tree blobs, the contents of EROFS images); a slot's closure
  adds every file of its boot partition (the firmware, the board's
  firmware for starting CPUs with its linker map, the device trees and
  `config.txt`). The packer fails on any file of unknown provenance. It
  writes `NOTICES` into every boot image and every EROFS image: the
  licence files of every contributing tree and artifact and, deduplicated,
  the header comment of every third-party file that carries a copyright
  notice, since BSD and MIT notices are per file; a file of erXos's whose
  SPDX line also names a third-party licence, as a file translated from
  Fiasco does, counts as third-party for its notice. `NOTICES` is laid
  out as FreeBSD's and Debian's copyright files are: each distinct header
  comment once, under the files that carry it, their licence and the
  licence files they cite, and then each licence file once, so a licence
  that thousands of files share costs one copy. A licence allowlist
  check fails the build when a closure holds a licence outside it, so an
  excluded file, such as one of Fiasco's excluded GPL parts, cannot come
  back unnoticed. The allowlist admits a copyleft licence only for a file
  that the packer places on its own, outside every executable and every
  EROFS image: the Pi 4's device tree, which ships with its source beside
  it; and it admits the Raspberry Pi firmware's binary licence for the
  files of a board's boot partition. Test images, which are never
  distributed, have an allowlist of their own that adds the licences of
  the test tools they carry, such as the Open POSIX Test Suite's
  GPL-2.0-or-later, and the packer refuses to mark a test image as a
  release. An image that holds the stopgap kernel has an allowlist that
  admits GPL-2.0 for exactly the GPL-headed files the stopgap keeps, each
  named in `fiasco/ORIGIN.md`, and the packer refuses to mark such an
  image as a release, since no image that carries the stopgap leaves the
  project as a release. The one such image that leaves it is the website's
  demo image, which the site serves with a link to the erXos source it was
  built from, a release tag or commit, so the GPL-2.0 files go out with
  their source offered ([site/README.md](../site/README.md)). The same `NOTICES` sits beside the boot image in each
  slot's boot partition, with the licence files of the firmware and device
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
* **A stopgap kernel.** A kernel that is not erXos's stands in for erXos's
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
monitors and exits between the pid spaces, so by the user's decision each
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
(Nerves).** They lost because the user chose ERTS, whose semantics,
performance and tools are what erXos is for, and because a conventional
kernel running an Erlang node does not make Erlang processes the system's
processes.

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| Two-level scheduling misses priority or latency targets that a kernel thread per process would meet | medium | high | E-S1, E-S2 and E-S8 on the same kernel before user domains build on it; urgency publication and the receive boost; the plain configuration as the fallback |
| Writing erXos's kernel takes longer than the plan assumes | medium | high | Phase 1b carries the user-facing system on the stopgap behind the unchanged interface (domains, programs, the web and the desktop, drivers in their domains, networking on QEMU), so the system is usable whatever the kernel's date, and only what needs erXos's kernel's guarantees waits for it; a pilot calibrates the effort before the kernel is written in full |
| The stopgap's modifications to Fiasco grow large | medium | medium | Fiasco stays near-stock: the backend carries only the part of the interface that Phase 1's system uses, refuses the rest with `ERX_ENOTSUP`, and builds no kernel mechanism in user mode; Fiasco's own mechanisms are reused where the interface allows |
| Cross-domain messaging costs too much for real applications | medium | medium | E-D1 before user domains build on it; doorbell batching; lazy decode; a lane is already a direct ring between the two parties |
| An Erlang driver misses a device's timing, or costs more than a stated fraction of its throughput | medium | medium | gate G9 measures interrupt-to-handler latency and ring throughput per device class on QEMU and the Pi 4 and decides batching; an exception is a row in the driver table with its measurement, run as a native shim in a sub-space port behind the same interface |
| A saturated service slows every client of it, since it runs on one capped grant | medium | medium | policy sizes each service's grant for the domains it serves and the service schedules its clients fairly within it; work that grows with a client's input runs in the client's own domain; per-client statistics in the inspector show where the time went |
| A session that ends abnormally loses the stores its programs made to shared mappings since the last write-back | medium | medium | write-back at `msync`, at every `close` of an open that maps it and at the file's last `close`, so a program that needs its stores kept asks for them with `msync`, as POSIX has it |
| A fault in the system domain's runtime resets the machine | low | high | the system domain's ERTS is every domain's but for the JIT, and every domain runs the interpreter in deterministic mode, so its runtime is exercised beyond the system domain; its services are supervised Erlang, so a bug there restarts a process; the watchdog bounds a hang; the crash record survives a warm reset where the platform has one |
| Owning the security fixes of ERTS, musl and Fiasco falls behind | high | high | a recurring review of each upstream's advisories against the kept parts; the funnel's positive grammar narrows what any decoder bug can be reached with |
| The network stack or the file systems, in Erlang, are too slow for the boards | medium | medium | the packet-path prototype measured on QEMU as a baseline, and gate GK3 deciding on erXos's kernel, with TCP's fast path in native code only if those numbers ask; the per-byte work in C primitives; `tools/erx bench fs` and the network benchmarks at G12 to G14 |
| Recombinations break Erlang semantics subtly | medium | high | a fast subset of the oracle on every change and the full suites at every major change; deterministic mode for reproduction |
| HVF lacks something the design assumes (MSIs through QEMU `virt`'s MSI frame, timer behaviour) | medium | medium | virtio-mmio with ordinary interrupts wherever no driver for the MSI frame exists; every suite runs under HVF |
| The Raspberry Pi firmware differs from QEMU in what the kernel relies on at entry (the initrd's placement, `/chosen`, the CPU's state) | medium | medium | the board port's first boot runs the boot probe and records the conventions in a research record, as for QEMU |

Decided provisionally on the user's behalf, each to be confirmed by the
user:

* **Translating from Fiasco.** erXos's kernel translates or copies code
  only from Fiasco files whose effective licence is permissive and whose
  provenance shows nothing else. A file takes the licence that Fiasco's
  `LICENSE.spdx` declares for its package, MIT for the kernel at
  `50bbe8a9`, unless its own notice says otherwise, and the import records
  each translated file's upstream history: GPL-2.0 counts a translation
  as a modification, so a file whose history shows GPL code is not
  translated, whatever its header says. `kobject_rpc.h`, which every
  build includes, and the kernel debugger's `jdb_object.cpp` are GPL-2.0,
  and erXos's kernel needs nothing either does
  ([Dependencies](#dependencies)). That any distribution outside the
  project waits for erXos's kernel is decided by CLAUDE.md's rule for
  stopgaps, not a question.
* **Login credentials.** The vault checks each passphrase by opening one
  of the principal's credential slots, kept on the vault's own partition,
  never in a file of the release, so no separate verifier exists; it
  limits attempts per name and per terminal and answers only whether a
  passphrase matched, after the same login envelope for every name.
  Argon2id runs at RFC 9106's second recommended option, 64 MiB, three
  passes and four lanes, until the login measurements, and no slot's
  parameters may exceed that ceiling; a principal enrols its first
  passphrase at the console's UART only, and a change needs the old
  passphrase; a slot made under another backend than the machine's opens,
  and moves to the machine's, only at the console's UART; one owner
  publishes each file, only over the generation it read; machine keys are sealed by the machine's
  backend without a passphrase; and the TPM's lockout parameters and the
  reserve of its tries for local terminals are set as
  [design-system.md](design-system.md#the-vault) gives them, its lockout
  authorization kept nowhere. Offline guessing, and forged, rolled-back or
  deleted files, as far as the backend leaves them, are residual risks
  ([Residual risks](#residual-risks)); under `tpm` the storage key is
  trusted on first use, and the set of enrolled principals is not anchored
  in the TPM.
* **A device secret through the root task.** On a board with a
  provisioned OTP key, the kernel's platform layer reads the key once at
  boot, derives a device secret from it and hands it to the root task on
  a page no other space receives; `liberx`'s root-task entry derives the
  vault's sealing secret from it into the sealing page, a memory object
  of the root budget, unmaps both pages and closes its capability to the
  device-secret page before ERTS starts; the domain library keeps the
  sealing page's one capability, never passes it, and maps the page
  read-only into the one domain of the release the boot image marks with
  `ERX_ENTRY_SEAL`, the vault's, and into no other. The kernel gains no
  call, the boards' firmware is reached once more at boot,
  and erXos never writes OTP; the page is a departure from Fiasco, which
  the kernel's L4 lineage ledger records
  ([design-platforms.md](design-platforms.md#device-secrets),
  [design-system.md](design-system.md#the-vault),
  [design-kernel.md](design-kernel.md#l4-lineage)).
* **The vault's partition in the MBR.** The boot medium's fourth entry is
  an extended partition holding the vault's partition and then the data
  partition ([design-storage.md](design-storage.md#data-model)).
* **Secure boot as an installation option** on the boards that offer it
  ([design-platforms.md](design-platforms.md#trust-in-the-boot)).
* **Late errors on the Raspberry Pi 4**, which has no error records, stop
  the presumed thread and mark the record as presumed
  ([design-kernel.md](design-kernel.md#interrupts-time-and-entropy)).
* **An own budget and an outer budget per domain.** The domain library
  carves each domain's two budgets side by side from the same parent. The
  own budget pays for what the domain alone maps and is destroyed at once
  when the domain ends, so every object of the domain's own dies with it.
  The outer budget pays for whatever another domain maps, each connection
  through a child budget of an outer budget, one per connection: a
  connection's lanes and doorbells, each lane to its reader's and both
  lanes of a domain's connection to the system domain to that domain's.
  Only its crash area is charged to the outer budget directly, so an outer
  budget holds exactly its connections' child budgets and its crash area.
  No domain holds an IPC gate of another domain, so memory crosses a
  domain boundary only through objects the system domain created, and it
  charges each to an outer budget or a child of one: the rule holds by
  construction. The domain holds no capability to its outer budget. The
  system domain destroys a connection's child budget once both parties
  have let go of it, and the outer budget once no child remains and the
  crash record is read, so no party ever faults on a dying peer's memory,
  the system domain spends none of its own budget on a domain's behalf,
  and a survivor that never lets go keeps alive that one connection's
  child budget and the outer budget it was carved from, with its crash
  area, but no other connection's lanes: the memory it pins is bounded by
  its own `connections` quota plus the dead domain's outer budget.
  Within a session, a program's budget holds only what the program alone
  maps; channel lanes, data areas and pipe rings are charged to the
  session's own budget, and the session deletes them after destroying
  the program's budget
  ([design-domains.md](design-domains.md#connections),
  [design-system.md](design-system.md#devices)).
* **Programs hang from anchors.** Each program is a threadless anchor
  space with its running image below it, under its starter's anchor, or
  under its session's space for a program the shell starts; its children
  hang from its anchor, so they survive its `exec`, and a program never
  outlives the program or session that started it
  ([design-programs.md](design-programs.md#a-programs-end)).
* **A program record outlives its images.** A program's handler keeps
  its identity, its children and their numbered states, and its signal
  reports, which no image can lose; an `exec` takes from the old image
  only what its `liberx` alone knows, and every channel message and
  capability value made for one image reaches no other
  ([design-programs.md](design-programs.md#the-handler)).
* **Each domain's pid is a process of its own.** One process per domain
  stands for it, linked to the domain service, which stops a domain whose
  pid dies, `kill` included, and ends the pid with `{domain_down, D,
  Info}` when the domain ends, so the two end together
  ([design-system.md](design-system.md#ending-a-domain)). The domain pid
  is also its domain's correspondent: the boot information names it,
  init reports ready to it, and it alone relays the connection protocol
  between the domain service and the domain's connection agent, so no
  export is written for the protocol alone, and it alone writes the
  domain's control table, a slot per connection outside every ring, so
  the protocol's records never wait behind other frames
  ([design-domains.md](design-domains.md#connections)).
* **A deletion closes first.** Deleting an object invalidates its
  existence lock before it empties its slots, in bounded parts, so the
  object is unreachable from the first part, where Fiasco empties every
  slot first; a departure of order the ledger records
  ([design-kernel.md](design-kernel.md#closing-and-deleting)).
* **`CAPS` stays with a space and its creator.** A space's capability
  leaves its creator's table with `INSPECT` alone, so only the space and
  its creator ever hold `CAPS` on it, and no domain installs anything into
  another domain's table ([design-kernel.md](design-kernel.md#invariants),
  K17).
* **An image change is the session's alone.** A program's `exec` replaces
  its image under its anchor, and its channel is made anew for the new
  image, so a message or capability value made for the old image reaches
  no other and no party outside the session takes part
  ([design-programs.md](design-programs.md#the-second-tier)).
* **Requester identity comes from fixed buses.** A device's DMA is
  confined only where the machine's fabric fixes its requester id, on
  QEMU `virt` the PCIe bridge's root bus, so no device can present
  another's ([design-kernel.md](design-kernel.md#dma-and-the-iommu)).
* **Every requested end has one owner.** The system domain latches an
  ending record and deadline before irreversible preparation. Only
  successful vault and storage preparation permits a trial; failure,
  timeout or coordinator death selects a normal reset, never a
  half-resumed system. Sessions write back their shared mappings before
  volumes checkpoint; incomplete durability is reported explicitly
  ([design-system.md](design-system.md#ending-a-domain)).
* **The watchdog's period and deadlines.** `erx.watchdog=P,D,B` sets
  them, with a 1 s period, a 5 s deadline after each pet and a 60 s boot
  deadline from the root task's start to the first pet by default; the
  kernel arms it when it starts the root task; ERTS pets it from a system
  process once each service it lists has answered a liveness call, and
  the root-task entry pets it itself in a bring-up boot, which the
  system manifest's `partial_boot` selects; a missed
  deadline ends the machine by `erx.panic`; in deterministic mode the
  watchdog is off; where a board has a hardware watchdog, the kernel
  reloads it from its own timer, never from the pet, so a kernel hang
  resets too
  ([design-kernel.md](design-kernel.md#the-watchdog),
  [design-platforms.md](design-platforms.md#the-watchdog)).
* **A program's group is a child of its session's.** Each program gets a
  group of its own under the session's programs group, so per-program CPU
  limits and statistics follow from the group tree, and no program
  exceeds its session; job control pauses the program's image, never its
  group, so a pause changes no CPU grant
  ([design-programs.md](design-programs.md#a-program-is-a-port)).
* **Capacity names a run.** The policy places each group's capacity on a
  run of CPUs so that the runs' shares on every CPU sum to at most one
  CPU, and a runtime keeps its active executors on its run
  ([design-system.md](design-system.md#resource-policy)).

Decided by the user, and recorded where each applies:

* **Holds act at the return check.** Pausing a space holds its threads
  only as they return to user mode, in the kernel's one return check, so a
  pause never interrupts kernel work: a pause returns once no thread of
  the space runs user code, a quiesce waits until none runs kernel code
  of calls it started, and neither waits for a party outside the space
  ([design-kernel.md](design-kernel.md#threads-and-faults), K30).
* **A copier per fork, in the program's group.** `fork` copies the
  parent's sub-space with `erx_space_copy` on a worker the session's
  port driver starts for that fork in the program's own group, where
  programs have groups of their own, so the program's grant drives the
  copy that holds it, while the child's budget, carved from the
  session's, pays for the child's memory; a parent has one copier at a
  time, and the forks in progress are bounded by the session's `programs`
  quota ([design-programs.md](design-programs.md#the-second-tier)).
* Linux's device tree for the Pi 4 ships unmodified
  ([Dependencies](#dependencies)).
* erXos's F2FS gets a legal review of its clean room before any
  distribution includes it
  ([design-storage.md](design-storage.md#read-write-storage)), and a data
  partition is never converted in place
  ([design-storage.md](design-storage.md#system-updates)).
* No backward compatibility in development: until a release promises
  compatibility, a change to anything erXos defines replaces the old form,
  with no conversion, migration, shim or reader for old versions, and an
  installation re-creates what an earlier build wrote
  ([Compatibility](#compatibility)).
* The vault's files live on a partition of their own, served by a
  storage domain whose only client is the vault, with littlefs until
  erXos's F2FS, which a fresh installation brings, with nothing carried
  across ([design-system.md](design-system.md#the-vault)).
* The roadmap: Phase 1's system on a near-stock Fiasco, then erXos's
  kernel, gated by the conformance suite
  ([Decisions](#decisions), [plan.md](plan.md)).
* erXos's kernel keeps Fiasco's two object locks, the capability lock and
  the existence lock ([design-kernel.md](design-kernel.md#l4-lineage)).
* Every domain is an Erlang node with a name of its own, its identifier
  at the machine's host name, with its domain id as the creation, and a
  domain that other machines reach carries its own distribution
  connections under that name
  ([design-domains.md](design-domains.md#domain-ids-pids-and-references),
  [Networking](#networking)).
* The kernel never dereferences a user address: every argument is a
  register, a UTCB field or a memory object with an offset and a length
  ([design-kernel.md](design-kernel.md#invariants)).
* Budgets are space banks: deleting a budget deletes every object charged
  to it, and ending a domain is destroying its budget
  ([design-kernel.md](design-kernel.md#budgets)).
* The system domain runs the interpreter; BeamAsm, asmjit and JIT objects
  are not in its image ([design-runtime.md](design-runtime.md#beamasm)).
* The system configuration is one manifest the build packs into the boot
  image and checks at build time
  ([design-system.md](design-system.md#the-manifest)).
* The file protocol is 9P2000.L: terms on connections inside the machine,
  9P2000.L's messages at the host link and on the network
  ([design-files.md](design-files.md#the-file-protocol)).
* An update's whole state is the boot-selection record's two states;
  F2FS stays the read-write file system, and erXos's
  F2FS refuses an image with the encryption, compression or atomic-write
  feature flags ([design-storage.md](design-storage.md#system-updates)).
* A program's socket is an open-file description of its session, so
  `posix_spawn`, `fork`, `exec` and `SCM_RIGHTS` within the session share
  or keep it as they do any open, and moving a socket to another domain
  is not offered
  ([design-network-stack.md](design-network-stack.md#the-interface-towards-posix-programs)).
* The vault, after Plan 9's factotum, stretches passphrases with
  Argon2id, keeps each principal's keys under a master key that the
  principal's credential slots wrap, and takes each slot's secret from a
  sealing backend behind an interface of its own
  ([design-system.md](design-system.md#the-vault)).
* A facet acts only for its grantee, so passing a facet's pid delegates
  nothing, and a program has no facets: anything beyond its session is a
  request to its handler ([design-domains.md](design-domains.md#facets)).
* Every cross-domain signal travels on a connection the system domain made,
  checked by the receiving runtime's funnel against its own export table;
  no third party carries or validates frames
  ([design-domains.md](design-domains.md#connections)).
* A program is a port of its session, in a sub-space of the session's
  domain, and its whole world is its session
  ([design-programs.md](design-programs.md#a-program-is-a-port)).
* No thread ever runs on another group's time: a shared service runs on
  its own capped grant and does bounded control
  ([design-scheduler.md](design-scheduler.md#service-work)).
* A stopped space's calls finish at a finishing level above every
  urgency, outside every quota, within each CPU's finishing share of 4 of
  every 8 ticks, measured by one step whose period comes from the clock;
  the stopgap has the level and not the share; their time goes to
  a separate `finishing_ns` counter of the finishing threads' own groups,
  never to the stopper's; reclamation is charged to the caller as every
  kernel call is. No grant can hold an exit record back, and no
  reservation exists
  ([design-kernel.md](design-kernel.md#execution-model-and-locking),
  [design-scheduler.md](design-scheduler.md#pick-and-dispatch)).
* The system domain is the root task, and a fault in it resets the
  machine ([design-system.md](design-system.md#the-root-task)).
* Drivers are Erlang, over a device NIF that parses nothing, with native
  exceptions only as rows of the driver table: "I definitely want most
  drivers in erlang with exceptions only when needed or perhaps with a
  small C shim for perf-critical parts"
  ([design-system.md](design-system.md#the-driver-table)). sDDF is a model
  and an oracle, not a dependency ([Dependencies](#dependencies)).
* A session serves its programs' shared mappings, with one object per
  file per session, coherent among the session's programs; two sessions
  see each other's stores after write-back, as on a network file system
  ([design-files.md](design-files.md#shared-mappings)).
* A file passed with `SCM_RIGHTS` lives as on UNIX, outliving its
  sender, since it is its open-file description, a process of the
  session, and a pipe end passed so is an end the session installs for
  the receiver, which outlives its sender
  ([design-programs.md](design-programs.md#passing-descriptors)).
* A `SIGCONT` that the `kill` rules let through continues a program the
  shell paused: it lifts job control's causes and tells the job table, and
  lifts no other hold, such as a `fork`'s copy's
  ([design-system.md](design-system.md#creating-a-domain)).
* Cryptography is OpenSSL 3.5, with a small verifier for update
  signatures ([Decisions](#decisions)).
* Plan 9's namespaces, file servers and factotum, and content-addressed
  code, are adopted; system code is Erlang, the network stack, the file
  systems and the drivers included ([Decisions](#decisions)).
* The command shell speaks rc's language, toybox is the toolbox, programs
  get a POSIX-ish interface so that UNIX programs need not be ported to
  Erlang, and the machine has a `/proc` tree and the rules for text
  ([Decisions](#decisions)).
* A program runs an executable file only through a grant with `rx`, and
  no grant carries `rw` and `rx` together; `system` and `popen` hand their
  command to `rc`; a file's offset lives in its open-file description, a
  process of the session shared by every program the description is
  passed to, and a read or write on a connection carries an explicit
  offset, as 9P2000.L does, so a passed file lives as on UNIX, outliving
  its sender; and a program ends with the program or session that
  started it, long-running services starting under a supervisor rather
  than detaching ([design-programs.md](design-programs.md)).
* `fork` and `exec` are absent from the first tier, where calling them
  fails to link; the second tier, toward QNX's level with dynamic
  libraries, adds them
  ([design-programs.md](design-programs.md#the-second-tier)).
* Linux binary compatibility and a Linux virtual machine are rejected
  ([Alternatives considered](#alternatives-considered)).
* The release process, the custody of the release signing key included,
  is outside this design ([plan.md](plan.md#beyond-the-plan)).

## References

* The research records of this repository, each dated, with its own
  sources:
  [research-hierarchical-scheduling.md](research-hierarchical-scheduling.md),
  [research-erts-internals.md](research-erts-internals.md),
  [research-erts-host.md](research-erts-host.md),
  [research-prior-art.md](research-prior-art.md),
  [research-kernel-bases.md](research-kernel-bases.md),
  [research-c-library.md](research-c-library.md),
  [research-baselines.md](research-baselines.md),
  [research-boards-storage.md](research-boards-storage.md).
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
