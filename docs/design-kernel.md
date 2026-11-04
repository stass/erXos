# The kernel

erXos's kernel is a capability microkernel written in C17 with a little
assembly for each architecture it runs on, built on the design and
know-how of L4Re's Fiasco and reshaped for erXos. It is the only code in
kernel mode. It owns what only privileged code may touch (exception and
interrupt entry, translation tables and the physical memory they map, the
interrupt controller, the timer, the other CPUs, and the few devices it
drives itself) and offers a small set of objects reached through
capabilities: budgets, spaces, threads, groups, memory objects, IPC gates,
IRQ objects, resources and DMA windows. Its key idea is Fiasco's object
model with every isolation property held by construction behind one
funnel: capabilities that cannot go stale, rights that only shrink,
objects whose deletion invalidates every capability to them at once,
allocations that are always paid for and that die with the budget that
paid, mappings that never exceed the capabilities that made them and
fault once their object is deleted, memory that is never writable and
executable at once, a kernel that never loads or stores through a user
address, and CPU time charged to the group of the thread that spent it.
It keeps Fiasco's process model: a
kernel stack per thread, a preemptible kernel with helping locks, and
calls that sleep where they wait. Until this kernel is written, a modified
Fiasco implements the same interface ([The current implementation: the
modified Fiasco](#the-current-implementation-the-modified-fiasco)). Every
place where erXos departs from Fiasco is listed, with its reason, in [L4
lineage](#l4-lineage). The architecture is in [design.md](design.md); the
scheduler is in [design-scheduler.md](design-scheduler.md); what each
processor architecture provides is in its binding,
[design-arch-aarch64.md](design-arch-aarch64.md) for AArch64, and each
board's facts are in [design-platforms.md](design-platforms.md).

Decisions every reader of this document needs:

* **One interface, defined in `abi/erx_abi.txt`.** Calls, rights, status
  codes, limits and every fixed layout come from one architecture-neutral
  file, and each architecture's register convention and in-memory hardware
  layouts from its own file beside it, `abi/arch/<arch>.txt`; from them
  the kernel's dispatch, `liberx`'s call wrappers and the Erlang headers
  are generated. `liberx` is the only code outside the kernel that issues
  a kernel call; its backends serve erXos's kernel, the stopgap and the
  hosted mode ([The ABI file](#the-abi-file)).
* **Fiasco's process model.** Every thread has a kernel stack, sized by
  the stack proof and guarded. A call that waits sleeps on its thread's
  stack and continues there. The kernel is preemptible: long operations
  run in bounded parts between preemption points, and a thread that needs
  a lock a preempted thread holds lends that thread its CPU, Fiasco's
  helping locks ([Execution model and locking](#execution-model-and-locking)).
* **Capabilities are the only authority for kernel objects.** A
  capability carries a generation, a type and rights; one lookup checks
  all three and the object's validity, and takes no reference; a slot
  retires before its generation wraps; rights only shrink. Capabilities
  are flat, as in Fiasco's object space: a copy adds a slot, closing
  removes only that slot, and deleting the object, with its delete right,
  invalidates every capability to it at once and unmaps it everywhere, so
  memory mapped from it faults from then on
  ([Closing and deleting](#closing-and-deleting)).
* **Objects die as in Fiasco.** Each object has Fiasco's two locks: a
  capability lock over the slots that name it, and an existence lock that
  an operation holds while it changes the object. Deleting an object
  closes it first, by invalidating its existence lock, after which nothing
  attaches to it and no operation begins on it; waits for the operation
  under way, if any; removes its capabilities and mappings in bounded
  parts; and frees it only after a read-copy-update grace period, when no
  call that looked it up can still be using it. That order departs from
  Fiasco's, which empties every slot before it invalidates the lock, a
  difference the [L4 lineage](#l4-lineage) records with its reason; the
  locks, the grace period and the free are Fiasco's. Objects hold no
  counted references to each other: a pointer from one object to another
  is an attachment of its target, which the target's teardown removes,
  and only a thread counts a reference, to keep an object across a wait
  or a preemption point ([Objects and
  capabilities](#objects-and-capabilities), [Execution model and
  locking](#execution-model-and-locking)).
* **Capabilities pass only at a rendezvous.** An IPC names at most four of
  the sender's capabilities as typed items in its message, each moved or
  copied with a mask, and the kernel installs them into slots the receiver
  reserved, in the operation that delivers the message, so no queue,
  message or ring ever holds one. Code, device and structural authority
  never passes between peers: it reaches a space only from the space's
  creator, the one holder of `CAPS` on it besides the space itself, whose
  `erx_cap_pass` into it is not bound by the pass sets ([Passing
  capabilities](#passing-capabilities)).
* **No kernel call takes a user address to dereference.** Every argument
  is a register value, a field of the calling thread's UTCB, which the
  kernel maps and reads once per field, or a memory object, an offset and
  a length, which the kernel reaches through its own mapping of the
  object. A user address appears only as a name: a page of a space that a
  range call or a mapping changes, resolved through the space's mapping
  records, and a umtx word, resolved by a walk of the caller's translation
  tables, which refuses a page outside the kernel's direct map, before the
  kernel reads it through its own mapping ([Arguments and
  results](#arguments-and-results), [Umtx](#umtx)).
* **Fiasco's IPC.** IPC gates bound to one thread each, with a label per
  gate; an open wait that receives from every gate and IRQ object bound to
  the waiting thread; messages of at most 63 words in the thread's UTCB,
  Fiasco's limit; IRQ objects that hardware or software triggers as
  doorbells; deadlines as IPC timeouts. A call is a rendezvous and nothing
  more: the serving thread runs on its own group's grant, and no call lends
  time ([IPC gates](#ipc-gates),
  [design-scheduler.md](design-scheduler.md#service-work)).
* **Spaces nest.** Any holder of a budget with `SPACES` creates spaces, as
  any holder of a Fiasco factory creates tasks. Every space but the first
  has a parent and stops when its parent stops, and a space whose last
  capability goes is torn down. The system domain creates every domain's
  space as a child of its own; a domain may create sub-spaces of its own
  ([Creating spaces](#creating-spaces)).
* **The system domain is the root task.** The kernel starts one user-mode
  task from the boot image and hands it the root capabilities; every other
  domain's space is its child, so every domain ends with it. A fault of
  the root task, or its halt outside an ordered shutdown, writes a crash
  record and ends the machine, and a watchdog that the root task pets does
  the same when the pet stops ([The root task](#the-root-task), [The
  watchdog](#the-watchdog)).
* **Signals are upcalls.** A worker armed with a vCPU state area, the part
  of Fiasco's vCPU interface that `liberx` needs, is diverted to its entry
  when an IRQ object bound to it is triggered; faults never take that path
  ([vCPU upcalls](#vcpu-upcalls)).
* **Every allocation is paid for, and dies with its budget.** Every
  kernel allocation names the budget that pays; budgets nest, each carved
  from its parent's; deleting a budget deletes every object charged to
  it, at once, as EROS's space banks do, so no charge outlives the budget
  it was made from, and what must outlive a domain is charged to a budget
  that outlives it ([Budgets](#budgets)).
* **Memory has fixed ceilings, no backing store and no pager.** A
  mapping's ceiling is fixed from the capability that made it, and
  changing its protection moves only beneath the ceiling; the mapping
  keeps its object until its space unmaps it or the object is deleted,
  and an access after the deletion faults; only private memory, which has
  no capability and is mapped exactly once, is freed by range; committed
  memory never faults for lack of memory; nothing is ever paged to
  storage. Every fault resolves from the object it touches or ends the
  thread with a fault record; no fault waits on another domain ([Virtual
  memory](#virtual-memory)).
* **A server never maps what a client can delete.** A server maps only
  memory it created or that the system domain created for a connection,
  and reaches memory a client owns only through copy calls
  that fail once the memory is gone
  ([Closing and deleting](#closing-and-deleting)).
* **No page is executable while anything can write it, and the kernel
  writes no machine code.** The kernel's code is fixed when it is built.
  The architecture layer makes every writable mapping execute-never, in
  hardware where the architecture provides it
  ([Port contract](#port-contract)). Code that is not compiled at run time
  lives in immutable objects, the boot image's slices and sealed paged
  objects, which no CPU or DMA mapping can write. Runtimes that compile
  code do so in user mode, into JIT objects mapped writable at one address
  and executable at another of one space, which no other space and no
  device can map, and publish what they compiled by an explicit step: the
  one alias the kernel allows. The root task's image makes no JIT objects,
  so none exists in the system domain ([Image
  manifests](#image-manifests)).
* **CPU time has one authority.** The kernel schedules threads within the
  grants of their groups, and no thread ever runs on another group's
  time; runtimes schedule their lightweight processes
  ([design-scheduler.md](design-scheduler.md)).
* **The boot image is mapped in slices.** Every file starts on a page of
  its own; no space maps the image whole; a slice covers a run of files,
  and only a holder of the `SYSTEM` right may slice files of the system
  release.
* **No FP or SIMD in the kernel; FP saved eagerly for threads.** The
  kernel is compiled so that it emits no FP or SIMD instruction, and every
  switch saves the full FP and SIMD state of the thread it leaves and
  restores that of the thread it enters.
* **A functional core with effects at the edge.** Every decision (a
  thread's next state, a plan for a range of memory, a pass, an IRQ
  object's next state, a charge, a scheduling decision) is a pure function
  or a plan validated whole; a thin effect layer writes translation
  tables, system registers and devices. The core builds for the host and
  its state machines are explored exhaustively there.
* **Generated hardware access, checked chokepoints, proven stacks.**
  Device registers are reached only through accessors generated from
  CMSIS-SVD files and each architecture's system registers only through
  accessors generated from one checked-in specification; every rule of the
  form "only X does Y" is a build check with a test; every build proves the
  worst-case depth of a thread's kernel stack, an interrupt on top
  included.
* **Architecture-neutral, with bindings.** Generic kernel code, its names
  and this document say kernel mode and user mode. The **port contract**
  ([Port contract](#port-contract)) lists what an architecture must
  provide, and each architecture's binding maps every item to its
  hardware: AArch64, the first, in
  [design-arch-aarch64.md](design-arch-aarch64.md). Boards are the
  platform binding's, [design-platforms.md](design-platforms.md): QEMU
  `virt` under TCG and HVF first, then the Raspberry Pi 4 Model B and the
  Raspberry Pi 5. A build check keeps each architecture's terms in its
  layer and its documents ([Chokepoint checks](#chokepoint-checks)).

## Context

erXos runs Erlang applications in protection domains in user mode, each
with its own runtime, its drivers among them; the system's own services
are Erlang processes in the system domain, the root task, also in user
mode ([design.md](design.md#overview)). The kernel underneath all of
them must provide isolation (memory, authority, CPU time) and nothing that
belongs to a runtime: no Erlang process model, no message format, no
scheduling of lightweight processes.

The kernel serves five parties:

| Party | Interface | What it needs |
| --- | --- | --- |
| Runtimes (ERTS) on executors | kernel calls through `liberx` | memory, groups, park and wake, umtx waits, time, entropy |
| Workers: the runtimes' own, native programs and device shims in sub-spaces | kernel calls through `liberx` | all of the above, plus IPC gates, IRQ objects, upcalls for signals, MMIO, DMA windows, spaces and threads |
| The system domain, as the root task | the root capabilities, the watchdog | authority over everything, to build the system ([The root task](#the-root-task), [design-system.md](design-system.md#the-root-task)) |
| The boot loader | the architecture's boot protocol ([design-arch-aarch64.md](design-arch-aarch64.md#boot-entry)) | a header, an entry in kernel mode or a more privileged mode, the device tree's address, the boot image inside the first stage's file or as the initrd |
| The operator | the early console, the panic path | the kernel's own log during boot, and a panic report that works when everything else is broken |

**Fiasco as the source of the design.** Fiasco has run as an L4 capability
microkernel on Arm for over a decade. erXos takes its object model
(capabilities naming kernel objects, factories charging quotas, IPC gates
bound to threads with labels, messages in a UTCB with capabilities as
typed items, IRQ objects as doorbells, the upcalls of its vCPU interface,
cross-CPU requests), its execution model (a kernel stack per thread, a
preemptible kernel, helping locks) and its know-how, and reimplements them
in C17. It departs where erXos needs something else: memory objects with
ceilings instead of flexpage mapping and user-level pagers, with no
page-fault IPC at all, kernel-assigned capability generations, budgets
that are space banks, spaces with parents, and the group scheduler of
[design-scheduler.md](design-scheduler.md). [L4 lineage](#l4-lineage)
records each departure with its reason and what keeping Fiasco's way would
lose. Fiasco at commit `50bbe8a9` boots unmodified under HVF on the
primary host when built to run in kernel mode without its hypervisor
support ([research](research-hierarchical-scheduling.md#fiasco-under-hvf)),
which makes it the stopgap behind this interface.

Prior art shapes the mechanisms. Fluke compares the process model with an
event model of restartable calls, and seL4 a non-preemptible kernel with
preemption points in its long operations
([research](research-hierarchical-scheduling.md#kernel-execution-models));
Fiasco's object space, in which each object keeps the list of slots that
name it, is the shape of erXos's capabilities, and seL4's capability
derivation tree is the alternative it declines. Zircon's handles carry
rights that duplication cannot add, and its regions carry ceilings
([research](research-kernel-bases.md#zircon)). Hubris makes a restarted
component's old names fail by generation. KaffeOS and seL4 charge kernel
memory to its beneficiary ([research](research-prior-art.md#kaffeos)), and
EROS's space banks destroy every object allocated from a bank when the
bank is destroyed. FreeBSD's `_umtx_op` is the
model for address-keyed waits. Linux supplies the ASID allocator with
generations, and KVM the one-instruction window that attributes a pending
asynchronous error to the code that caused it; the AArch64 binding names
both sources
([design-arch-aarch64.md](design-arch-aarch64.md#exception-and-interrupt-entry)).

## Requirements

Functional requirements:

1. **Boot.** Boot by each platform's boot protocol on QEMU `virt` under
   TCG and HVF and on the Raspberry Pi boards
   ([design-platforms.md](design-platforms.md)), on one CPU and on
   several, entering in kernel mode or in a more privileged mode, which it
   leaves for good; validate the device tree and the boot image; bring up
   the other CPUs; start the root task with the root capabilities.
2. **Objects.** Provide budgets, spaces, threads, groups, memory objects,
   IPC gates, IRQ objects, resources and DMA windows, each reached only
   through capabilities, each deletable for every holder by a holder of
   its delete right, and each deleted with the budget that pays for it.
   A budget has a guarantee no other budget can take and a cap up to
   which it spends what its ancestors have not promised; its carver
   resizes both while it lives, and a holder can ask to be told before
   it is refused.
3. **Kernel calls.** Provide every call of `abi/erx_abi.txt`, with
   generated decoders and the contracts given here, to executors and
   workers alike, with the executor rule of
   [design-scheduler.md](design-scheduler.md#executor-class-enforcement),
   each taking its arguments from registers, the caller's UTCB and memory
   objects it names, never from a user address.
4. **Spaces.** Let any holder of a budget with `SPACES` create spaces,
   each with a parent it never outlives, a fault gate it never changes,
   and a capability table only its creator can fill without asking.
5. **Memory.** Reserve, commit, decommit and release private memory;
   shared, contiguous and physical memory objects; device memory for MMIO;
   memory objects that runtimes map writable at one address and executable
   at another; read-only images from boot-image slices; population
   reserves that keep committed memory from faulting for lack of memory.
6. **Communication.** IPC through gates bound to threads, with calls,
   replies, open waits, labels that name the client, timeouts and
   capabilities passed at the rendezvous; IRQ objects as doorbells, bound
   to a thread or a group; and umtx waits.
7. **Signals.** Upcalls into an armed worker when an IRQ object bound to
   it is triggered, with no event lost between an upcall and its return.
8. **Faults.** A fault resolves from the object it touches, or stops the
   thread and sends a typed fault record to its space's fault gate; no
   fault waits on another party, and nothing a thread does panics the
   kernel.
9. **Interrupts and time.** Own the interrupt controller and the
   platform's MSI frame ([design-platforms.md](design-platforms.md) names
   each platform's); deliver device interrupts through IRQ objects to
   threads or groups; give monotonic and wall-clock time through a
   read-only page.
10. **Drivers.** MMIO windows, interrupt lines, MSIs and DMA windows
    behind the IOMMU as objects; the streams of PCIe functions by
    requester id, only on buses whose requester ids the fabric fixes;
    every other device declared unconfined. Configuration space is not the
    kernel's: the PCIe enumerator, an Erlang process in the PCIe domain,
    owns it ([design-system.md](design-system.md#devices)).
11. **Scheduling.** The first level of
    [design-scheduler.md](design-scheduler.md).
12. **Diagnostics.** An early console for the kernel's own log, a kernel
    log that the console service reads, a per-CPU trace ring, inspection
    of every object, a panic report, and a deterministic mode.
13. **Entropy.** A generator seeded at boot, from a seed every release
    build requires.
14. **The machine.** Ending the machine (off, reset, as a panic, or into a
    system update's trial), and on a trial boot a lease after which it
    resets.
15. **The root task and the watchdog.** Start the system domain as the
    root task, the parent of every domain's space; end the machine, after
    a crash record, when it faults, halts outside an ordered shutdown or
    stops petting the kernel's watchdog; reload the board's hardware
    watchdog for as long as the kernel runs; hand the previous boot's
    crash record to the root task ([The root task](#the-root-task), [The
    watchdog](#the-watchdog)).

Non-functional requirements:

* **Small.** 25,000 to 40,000 lines of C17 and under 2,000 lines of
  assembly per architecture, an estimate: Fiasco's AArch64 build measures
  66,837 preprocessed lines, and about 43,400 without its kernel debugger,
  its mapping database and its priority-inheritance mutex, which this
  kernel does not have (inferred from the measured breakdown,
  [research](research-hierarchical-scheduling.md#fiasco-sizes)); this
  kernel also drops ACPI, the hypervisor support, most of the vCPU
  interface, flexpage mapping of memory and IPC donation, and adds
  generations, budgets, groups, memory objects and the watchdog, each a
  small part of the whole. The pilot of [plan.md](plan.md) calibrates the
  figure.
* **Bounded.** Every kernel path does work bounded by the ABI's limits
  between preemption points, never by state built up earlier. No call
  copies more than `ERX_COPY_MAX` (1 MiB); no stretch with interrupts
  masked lasts longer than 20 microseconds under HVF
  ([Performance](#performance)).
* **Proven stacks.** Every build proves the worst-case depth of a
  thread's kernel stack, with an interrupt taken on top of its deepest
  frame, and of every other stack ([Stack proof](#stack-proof)).
* **Accounted.** Every byte of kernel memory, kernel stacks included, and
  every reserved user page is charged to a budget for as long as it
  exists, and counted against the guarantee of exactly one budget on its
  chain of ancestors, or the root's; address space that holds no page is
  not memory and costs its record alone.
* **Hostile user mode.** Any user-mode code may be malicious. No sequence
  of calls, faults or device actions from a domain or a sub-space panics
  the kernel or crosses a boundary between spaces that its capabilities do
  not grant.
* **Fast crossings.** A null kernel call costs at most 40 ns and an IPC
  call round trip on one CPU at most 300 ns under HVF
  ([Performance](#performance)).
* **Portable and reproducible.** Architecture code stays behind the
  architecture layer, which implements the port contract, and board facts
  come from the device tree and the platform layer; the same inputs give
  the same kernel image, and deterministic mode gives the same transcript.

Non-goals:

* Policy: who gets which budget, grant, device or capability is the system
  domain's ([design-system.md](design-system.md)).
* Any knowledge of Erlang, of frames or of pids: the runtimes own them,
  and a lane's ring and doorbell are a memory object and an IRQ object
  like any other ([design-domains.md](design-domains.md#connections)).
  The kernel knows spaces, not domains: a domain is a space the system domain
  created and keeps a record of.
* Capabilities queued in messages, flexpage mapping of memory, and
  pagers: capabilities pass only at a rendezvous, a mapping is made only
  from a memory object a capability names ([Passing
  capabilities](#passing-capabilities)), and every fault resolves from
  its object or ends the thread.
* Consoles: the console and the host link are UARTs that their drivers
  drive, the console's in the system domain; the kernel writes only its
  early console, the console's UART during boot and at the machine's end
  ([Console, log and panic](#console-log-and-panic)).
* POSIX, Linux system calls, ELF parsing, paging to storage, CPU hotplug,
  and power management beyond waiting for an interrupt and the firmware's
  calls that start CPUs and end the machine.
* PCIe configuration space, enumeration and BAR assignment: the PCIe
  enumerator owns them ([design-system.md](design-system.md#devices)).
* Device drivers beyond the devices of `hw/kernel_devices.txt`
  ([Resources, DMA windows and consoles](#resources-dma-windows-and-consoles))
  and the firmware calls that start CPUs and end the machine.
* A hypervisor, virtual machines and the vCPU interface's user mode: the
  kernel leaves any mode more privileged than kernel mode at boot and never
  returns to it.
* Vector extensions beyond the base FP and SIMD registers: they stay
  trapped ([design-arch-aarch64.md](design-arch-aarch64.md#fp-and-simd-state)).
* A randomised kernel virtual layout: user mode cannot read kernel memory,
  and where the architecture can make user-mode accesses to the kernel's
  half fault in constant time, the binding enables it
  ([design-arch-aarch64.md](design-arch-aarch64.md#translation)).

## Overview

```text
     user mode: executors and workers of every domain and sub-space (the system
                domain, which is the root task; ERTS domains; programs and shims)
   --------------------------------------- system-call trap, faults, interrupts
   entry -> generated dispatch -> handlers, on the running thread's kernel stack
   +--------------+--------------+----------------+-------------------+--------------+
   | capabilities | threads,     | spaces and     | IPC gates and     | resources,   |
   | and rights   | faults,      | their parents, | UTCBs, IRQ        | DMA windows  |
   | one lookup,  | upcalls,     | memory objects,| objects, umtx     | (IOMMU)      |
   | no reference | scheduler    | windows        |                   |              |
   +--------------+--------------+----------------+-------------------+--------------+
   | budgets (every allocation          | RCU grace periods,      | early console,    |
   | charged; space banks)              | reaper (bounded steps), | log, trace, panic,|
   |                                    | cross-CPU requests      | crash record,     |
   |                                    |                         | watchdog          |
   +----------------------------------------------------------------------------------+
   | architecture layer: boot entry, exception  | platform layer: device tree, the    |
   | and interrupt entry, switch, translation   | devices of hw/kernel_devices.txt    |
   | and TLB, caches, the direct map, firmware  | (interrupt controllers, MSI frames, |
   | calls                                      | timer, early console, IOMMUs)       |
   +----------------------------------------------------------------------------------+
   | physical page allocator: buddy allocator over 4 KiB pages with page records     |
   +----------------------------------------------------------------------------------+
     kernel mode: no FP or SIMD; a kernel stack per thread; preemptible between
     bounded parts; helping locks and leaf spinlocks
```

A day in the life, end to end:

1. **Boot.** The boot CPU enters by its platform's boot protocol, with the
   device tree's physical address in its first argument register. The
   kernel writes its early console from its first step, leaves any more
   privileged mode it entered in, validates the device tree and checks
   that it names that console, builds its translation tables, seeds the
   page allocator, initialises the interrupt controller and timer, validates
   the boot image, seeds the entropy generator, creates the root objects,
   starts the other CPUs, prints the banner, and starts the root task,
   the system domain, from the boot image with the root capabilities.
2. **A kernel call.** An executor of domain `web` calls `erx_vm_commit`.
   The entry saves its registers into its thread record, on its own kernel
   stack, the generated dispatch checks the call number and the executor
   rule, decodes each argument (the space capability through the one
   capability lookup, the range as page numbers), and calls the handler.
   The handler plans the change, charges `web`'s budget for the reserve,
   applies the plan, and returns a status. The lookup took no reference:
   the space cannot be freed before the call passes a preemption point,
   so the dispatch simply returns to user mode.
3. **A wait, and an interrupt.** A worker of a file server calls
   `erx_ipc_wait` with nothing pending. It sleeps on its kernel stack, and
   the CPU switches to the next thread the scheduler picks. When a client
   calls through a gate bound to that worker with a label, the worker
   becomes ready, continues in its wait, and returns with the label. In
   the network domain, meanwhile, the device interrupts: the line's IRQ
   object, bound to the domain's group with a label, lists itself on the
   group's ready list and wakes a parked executor, which takes the label
   with `erx_group_take_ready` and hands the event to the driver process
   ([IRQ objects](#irq-objects)).
4. **A fault.** A thread of an untrusted domain reads an unmapped address.
   The fault classifier finds no mapping, so the thread stops, and its
   fault record goes as a message to its space's fault gate, a gate bound
   to a thread of the system domain's `liberx`, which receives it with the
   label it gave the space at creation, the domain's id, and stops the
   domain; the domain service turns the exit record into
   `{domain_down, D, Info}`
   ([design-system.md](design-system.md#ending-a-domain)).

**A functional core with effects at the edge.** The kernel decides in pure
functions and acts in a thin effect layer:

| Core | Shape | Effects that carry it out |
| --- | --- | --- |
| a thread's life, `erx_thread_step` | state machine over `READY`, `RUNNING`, `WAITING`, `STOPPED`, `DEAD` | the switch, the wait queues, cross-CPU requests |
| a fault's kind, `erx_fault_classify` | the fault as the architecture layer decoded it in, the typed fault record out | population, stopping the thread, the fault message |
| an IPC transfer, `erx_ipc_step` | state machine over the sender's and the receiver's states: open and closed waits, queued senders, timeouts, deaths, destroyed gates | the switch, wakes, the message copy |
| a pass, `erx_pass_plan` | the typed items and the receiver's room in, the whole pass or one status out | `erx_pass_take` under the sender's table lock, then `erx_pass_install` under the receiver's: slots and the objects' slot lists |
| a deletion, `erx_delete_step` | the object's state, its slot list and its mappings in, the next bounded part out: invalidate, clear slots, remove mappings, wake waiters, or queue the put behind a grace period, which for a space is queued only by the walk that unlinked it | clearing slots, unmapping, IOMMU and TLB maintenance, the RCU queue |
| an IRQ object, `erx_irq_step` | state machine over binding, a queued delivery and, for a hardware line, masking | masking at the interrupt controller, delivery to a thread or a group |
| an upcall, `erx_vcpu_step` | state machine over events enabled, an event pending, an upcall in progress and the thread's wait | saving the frame, entering the entry, resuming |
| stopping a tree of spaces, `erx_stop_step` | the walk's current space, the head of its list of children and the space where the walk began in; stop that child and descend, return to the parent, or finish, out | the stopped words, inter-processor interrupts, exit records once each space's children have posted theirs |
| deleting a tree of spaces, `erx_delete_walk_step` | the walk's current space, the head of its list of children and the space where the walk began in; delete that child and descend, return to the parent, or finish, out | the child's close and its own deletion's parts |
| scheduling | `erx_sched_resolve`, `_charge`, `_draw`, `_pick`, the park and deferred-preemption machines ([design-scheduler.md](design-scheduler.md#algorithms-and-behavior)) | queues, timers, switches |
| system-call decoding | registers, the message tag and the UTCB fields it implies, each loaded once, decoded arguments or a status out | the handler |
| budgets: carving, charges, refunds, resizes, the borrowing chain, the watch's crossing, a destroyed budget's charges moving to its parent and its tombstone's release | `erx_budget_adjust`'s plan over the chain's counters, with the IRQ objects to trigger out | updating the counters under the locks; the triggers after them |
| range calls (`erx_vm_*` and `erx_space_protect`) and `erx_image_map`, `erx_vm_plan` | a plan of the records to split, detach and create, the reserve to charge and the entries to edit, validated whole with its allocations made and its charge taken before anything changes | `erx_vm_apply`: records, tables, TLB maintenance |
| invalidation, `erx_tlb_plan` | the entries a plan clears, each a page or a table entry with its span, in; the invalidations, every level for a table entry, last level for a page, or the whole ASID, out | the binding's TLB and IOMMU invalidations, then freeing what the entries covered |
| asynchronous error attribution, `erx_async_error_classify` | where the error was taken and what the architecture reported in, the action out | stopping a thread, logging, panic |
| the watchdog, `erx_watchdog_step` | its state (off, unarmed, armed with a deadline), an event (the root task's start, which arms the boot deadline `B` ahead; a pet, which moves the deadline `D` ahead; a tick of the timer, which checks it) and the mode in; the next state and arm, reload or end out | the timer, the board's watchdog through the platform layer, the crash record and the end funnel |
| the capability table and the objects' slot lists, the mapping tree, the RCU batches, the buddy and ASID allocators, the trace and log rings | data structures over memory they are handed | none |
| the boot-image validator, the slice check, the manifest check, the device-tree and command-line parsers | functions over bytes | none |

The effect layer is the architecture layer, `kernel/arch/<arch>/`
(`kernel/arch/aarch64/` first), and the platform layer, `kernel/platform/`:
system registers, translation-table writes, cache and TLB maintenance, the
context switch and exception return, firmware calls, and device registers,
each reached through generated accessors
([Hardware register sources](#hardware-register-sources)). No caller
strings effects together in an order it must remember: a plan or a state
machine's action list names them, and one function applies them.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **K1.** A stale capability never names a fresh object | every call reaches an object only through `erx_cap_lookup`, which checks the slot's generation, type and rights and refuses a deleted object and an object whose budget is destroyed, a slot retires before its generation wraps, and the object a lookup returns is freed only after a grace period that begins after its deletion, so it stays valid until the call's next preemption point ([Objects and capabilities](#objects-and-capabilities)) | a call that accepts an object pointer, a raw object identifier or another table's value; a narrower generation; reuse of a retired slot; a lookup's pointer used after a preemption point | `tools/gen_abi.rb` refuses a capability argument without a type and rights, and emits every call's plain lookups after its other arguments; the epoch of each `erx_uref_t`, checked in debug and host builds; a host test drives one slot through retirement; a domain test uses a closed capability and expects `ERX_ESTALE` |
| **K2.** Rights only shrink | a rights value is built only by `erx_rights_create`, which returns the validated creation kind's default set from the ABI file, and by `erx_rights_shrink`, which intersects with a mask; copying, passing and carving use the second, carving with the parent capability's rights and `DESTROY` as the mask, so the carver may delete what it carved and nothing more; nothing combines rights by OR | a third constructor, or an expression that ORs into a slot's rights | a source check that `erx_rights_t` is constructed only in `kernel/core/cap.c`; a host property test that every copied or passed capability's rights are a subset of its source's, and every carved one's a subset of its parent capability's and `DESTROY`; the generator's check that each carved kind's created rights lie within its parent's created rights and `DESTROY` ([Rights](#rights)) |
| **K3.** Every kernel allocation is charged to a budget, an object dies with its budget, and no budget's tree spends beyond its cap | `erx_kalloc` and `erx_reserve_charge`, the one source of pages, take a budget or a reserve that names one, and have no other variant once the root budget exists; a thread's kernel stack and kernel-user page are charged with the thread; carving a child charges its guarantee to the parent; every object joins its budget's list of charged objects through that list's insert function, which refuses a destroyed budget, and a budget's destroy deletes every object on the list, child budgets included; objects point at each other only through attachments, which each teardown removes, so nothing outside a budget keeps what it paid for; a destroyed budget's record stays as a tombstone, its counters excluded from the aggregate and the cache page it sits in charged to its parent, until the last object charged to it is freed; every change of a budget's counters goes through `erx_budget_adjust`, which refuses a charge that would take any budget's spending above its cap ([Budgets](#budgets)) | an allocation path without a budget; a cache shared between budgets; a boot-time allocator reachable after the root exists; an object that is on no budget's list; a pointer between objects that is not an attachment; a budget record freed while an object charged to it lives; a counter written outside `erx_budget_adjust` | a link check that no budget-free allocation symbol is referenced outside boot code; the source check that every pointer between object records is an attachment field; the chokepoint check that the budget counters are written only in `erx_budget_adjust`, with a seeded violation; exhaustion tests through every object type; a domain test that destroys a budget whose objects other domains hold and map, and finds every capability to them failing with `ERX_ESTALE`, every mapping of them faulting with `ERX_FAULT_DELETED`, and the parent's room and unspent guarantee whole again when the destroy returns, but for the cache pages of the destroyed records, and whole once their grace period and the reaper's steps for them have run, which the test waits for by draining the reaper; a test that parks a thread of another budget inside `erx_mem_copy` across the destroy of its source's budget and finds the copy failing with `ERX_ESTALE` at its next part and the tombstone freed after it, under ASan on the hosted kernel; a test that destroys a budget at each step of a thread's, a child's and a space's construction, and between every insert of its publication, on the hosted kernel, and finds the creation returning `ERX_ESTALE`, every page it backed refunded at the dead budget before the destroy returns, and the tombstone freed, with a seeded construction that admits its first part before its record joins the budget's list, which the release core's model catches as a charge the destroy's walk cannot find, left at a dead budget |
| **K4.** A mapping never allows more than the capability that made it | `erx_vm_map`, `erx_image_map` and `erx_dma_map` fix each mapping's ceiling as the capability's rights intersected with the object's ceiling and refuse a protection above it; `erx_space_copy` copies a mapping with its ceiling; no call raises a mapping's protection above its ceiling: `erx_space_protect` moves a mapping's protection only beneath it, committing a reservation it gives access to, and commit and decommit move private memory between no access and read-write, beneath private memory's fixed ceiling | a protection computed from anything but the ceiling; a protection-changing call that ignores it | host tests of the ceiling arithmetic; a domain test maps an object read-only and tries every call that could make it writable, `erx_space_protect` failing with `ERX_ERIGHTS`; a domain test that protects committed private memory to no access and back and reads its contents unchanged |
| **K5.** Trimming never meets sharing | only private memory is ever freed by range; private memory has no capability, so no call can map it twice, and its mapping records partition its offsets, so each of its pages has exactly one address; every other kind keeps its pages until the object is destroyed | a call that maps private memory a second time, or a range call that frees a shared object's pages | a domain test maps a shared object at two addresses, decommits and releases one view, and reads the other |
| **K6.** Committed memory never faults for lack of memory, and no fault waits | making memory accessible first reserves and charges every page its population can need, translation tables included, whether `erx_vm_commit` or an `erx_space_protect` that gives a reservation access makes it accessible, and backs the reserve with pages in the same call: a charge borrows through the budget chain at that moment, never at a fault, and takes its pages from the allocator then, taking released pages off the released list and waiting their grace period when none is free, which is bounded and waits on no party, so between calls a reserve's pool holds a page for every promise not in use; a fault populates from that pool, copies on write from one, or stops the thread with a fault record, under the owner's lock, and touches neither the allocator nor a budget; a translation table goes only with the promise that reserved it, so a rebuild needs only the pool; the fault decision has no result that sends a message or waits ([Virtual memory](#virtual-memory), [The reaper](#the-reaper)) | a take beyond a reserve's pool; a charge that promises more than it backs; a protect that gives a reservation access without the reserve; a fault path that reaches the allocator or waits; a table detached while a record that holds a promise touches its span; a page released without its refund, which would leave a charge with no page behind it | a host model of the accounting checked after every random operation, which finds every reserve's pool holding a page for every promise not in use between calls; the fault decision's exhaustive host model over every mapping kind, page state and access, in which every result populates from a pool, copies on write from one or stops the thread; a domain test commits a whole budget sparsely and touches every page while every other page of the machine is held, the free lists and the released list empty throughout, every touch succeeding and the allocator's take counter unchanged by them; a domain test that reserves beyond its cap, gives parts access by `erx_space_protect` up to the cap, protects them to no access and back, and touches every page of them, with a seeded protect that skips the charge and a seeded protect that detaches a table, which the model catches; a domain test in which one domain releases and commits without pause on three CPUs while another commits and touches a fresh range on the fourth, every commit backed within two grace periods per part of 64 pages and every touch succeeding, with a seeded backing that takes nothing off the released list, under which the commit waits past its bound, which the test catches; the host model that closes a backing's owner at every part boundary of a charge of 129 pages, after which the reserve's `charged` equals its `backed`, every page of the backing is on the released list exactly once and the budget is back at its baseline, with a seeded backing that releases its hand itself, which the model's once-only check catches, and a seeded one that skips the cancellation, under which `used` stays high |
| **K7.** The kernel never loads or stores through a user address, and reads memory user mode can write once per field per decision | no call takes a user address to dereference: every argument is a register value, a field of the caller's UTCB or a memory window ([Arguments and results](#arguments-and-results)); a user address is decoded only into `erx_uvpn_t`, which only the space's mapping records resolve, or `erx_uword_t`, which only `erx_uword_load`'s walk of the caller's translation tables resolves, and nothing converts either to a pointer; the kernel reaches UTCBs, shared areas and memory objects' pages through its own mappings, reads a field user mode can write only through `erx_shared_load_*`, one load per field per decision, moves message words only through `erx_msg_copy`, and moves a window's bytes only through `erx_window_read` and `erx_window_write`, deciding nothing on what they carry | a call argument that is a pointer; a conversion of a user address to a pointer; an access through a user translation; reading a shared field twice in one decision; a decision on bytes read from a window | the ABI grammar has no pointer type; a syntax-tree check that the kernel makes a pointer from an integer only in the converters of [Typed values](#typed-values) and the generated accessors; a disassembly check that the architecture's unprivileged access forms appear nowhere in the kernel; hostile rewrites of UTCBs, control areas and windows while the kernel reads them |
| **K8.** No page is executable through one mapping while it is writable through another, by the CPU or a device, except a JIT object's pages within the one space that made them, and the kernel writes no machine code | the architecture layer forces every writable mapping execute-never, in hardware where the architecture provides it ([Port contract](#port-contract)); the kernel's text is mapped executable once at boot and is outside the direct map; no kernel call creates an executable kernel mapping; a user mapping is refused if it asks for write with execute; besides JIT objects, only immutable objects have an execute ceiling: the boot image's slices, which nothing writes, and paged objects that the system domain, holding `CODE`, which never leaves its table, creates with an execute ceiling and that are mapped only once sealed, a seal succeeding only while no CPU or DMA mapping can write the object and no such mapping being made after it ([Copy-on-write children and copies of spaces](#copy-on-write-children-and-copies-of-spaces)), so no code has a writable alias, a device's included; a JIT object is mapped writable at one address and executable at another, never both in one mapping, and only in its owner, the space created with `ERX_SPACE_JIT` whose thread made it, which needs `CODE` on the budget or a JIT space as the creator's own, since the object records its owner at creation and `erx_vm_map` refuses every other space, and never in a DMA window; it carries no `DUP`, `GIVE` or `CHILD`, so no capability to it leaves its owner and no mapping reaches another space, and nothing outside its one space aliases its pages, and its runtime moves code from written to runnable by an explicit publication step ([Virtual memory](#virtual-memory)); a copy-on-write child's ceiling never includes execute | a direct map that covers kernel text; turning the hardware enforcement off; a user mapping with both; an execute ceiling on an object that can still be written; a seal that overlooks a writable DMA mapping; a JIT object in a DMA window; a JIT space made by a creator that is neither; a JIT object mapped into a space other than its owner | a walk of the kernel tables at boot and after every test that finds no writable and executable entry; a domain test that asks for every combination; a domain test in which a JIT space creates a JIT sub-space, maps its JIT object writable in itself and then into the sub-space, which fails with `ERX_ERIGHTS`; a domain test that a sub-space created with `ERX_SPACE_JIT` from a space without it fails with `ERX_ERIGHTS`; a test that seals an object a DMA window maps writable and finds the seal failing with `ERX_EBUSY`; a test that `erx_dma_map` of a JIT object fails with `ERX_ETYPE`; a test that `erx_mem_create_paged` with `ERX_MEM_CODE` and `ERX_MEM_WRITABLE` together fails with `ERX_EINVAL` |
| **K9.** No translation outlives its access | user mappings are non-global and tagged with their space's ASID; every removal, a mapping removed because its object was deleted included, invalidates what it made stale and waits before a page or table it covered is freed or reused; the invalidation follows from the kinds of entry cleared, so a cleared table entry is always dropped from walk caches over its span or with the whole ASID, by `erx_tlb_plan` ([Virtual memory](#virtual-memory)); a dead space's ASID is invalidated before its tables are freed; an IOMMU unmap completes the IOMMU's synchronisation, with its every-level form for a cleared table entry, before its pages' reference drops | a global user mapping; a free before the invalidation completes; a last-level-only invalidation for a cleared table entry, which leaves a walk cache pointing into a freed table | the plan's host test over random ranges and table shapes; an isolation test that hands freed pages and freed tables between domains on four CPUs under HVF and on the boards, since TCG need not keep walk caches; a host test of the maintenance helpers' order |
| **K10.** The kernel never executes FP or SIMD instructions | it is compiled so that the compiler emits no FP or SIMD instruction, with the flags the architecture binding names; its memory primitives are general-register code, and its objects' references to `memcpy`, `memset`, `memmove` and `memcmp` are renamed to them; the only FP instructions in its objects are the save and restore routines of the switch | an object built without the flag; a call into a SIMD routine | a link-time scan of kernel objects for FP and SIMD encodings outside the two routines |
| **K11.** Every thread's FP state survives every switch | every switch away from a thread saves its whole FP and SIMD register state, with the control and status registers, and every switch to one restores it; the kernel's own code never touches FP (K10); an upcall leaves the FP state live | a lazy scheme that misses a path | a stress test that interleaves float-heavy threads on every CPU with interrupts, preemption in the kernel and upcalls |
| **K12.** Nothing a user-mode thread does panics the kernel, except a fault of the root task, which holds the root authority and which nothing can recover, so the kernel writes a crash record and ends the machine ([The root task](#the-root-task)), and an asynchronous error that the architecture reports as uncontainable, a residual of the hardware | every synchronous exception from user mode goes, by an exhaustive `switch` on the exception's class with a default arm, to the dispatch, to page population, or to stopping the thread with a typed fault record ([Threads and faults](#threads-and-faults)); an asynchronous error is contained at the device the platform's error records name, or at the thread a window presumes, and panics only when the architecture reports it uncontainable ([Interrupts, time and entropy](#interrupts-time-and-entropy)); a malformed call returns a status | a user-mode exception class routed to the panic path; a contained asynchronous error routed to it | a fault-injection program that raises every user-mode exception class; a call fuzzer domain under TCG and HVF; a test build whose root task faults on purpose, which finds the crash record on the console and the end the configuration names |
| **K13.** Every kernel path is bounded between preemption points | a handler does at most one bounded part of its work between preemption points, where pending interrupts are taken and its thread may be preempted, and holds no spinlock across one; every spinlock is a ticket lock, served in the order of arrival, so a part that takes one is behind at most `ncpus - 1` holders, each inside a bounded part with interrupts masked, and a part's bound counts those holders' critical sections for each lock it takes; every stretch with interrupts masked is bounded by the ABI file's limits; the generator rejects a call without a declared bound per part; a wait holds no spinlock and no helping lock | a loop over input-sized state without a preemption point; a spinlock held across a preemption point or a wait; a spinlock without a queue, under which one CPU can be passed over without bound | the per-call bound in the ABI file; a timing test of every call at its limits under HVF that measures its longest stretch with interrupts masked; hostile tests that block threads on objects nobody signals; a host test of the ticket lock under TSan with `ncpus` threads contending without pause, which finds every acquisition served within `ncpus - 1` releases, with a seeded unqueued lock, under which one thread is passed over past that bound |
| **K14.** A thread runs on at most one CPU, and a thread that is woken never runs before its switch out has completed | a thread's state and its kernel stack belong to its home CPU; other CPUs change them only by posting requests, each attached to the thread and not to a CPU, which the home CPU drains; a thread is moved only by its home CPU, a running one from the idle context; the one exception is helping, as in Fiasco: while a thread holds a helping lock and is preempted, a helper may run it on the helper's CPU until it releases the lock, and that CPU then owns its state until the switch back, which the thread's running-under-lock flag serialises; a thread that sleeps is switched out before the kernel releases its CPU's state; wakes from other CPUs are requests applied in order | a remote CPU writing a thread's state directly outside helping; a thread run by two CPUs at once | a host model checker over the thread state machine with requests and helping, the stack switch as separate steps ([design-scheduler.md](design-scheduler.md#concurrency)); a stress test that races wakes, waits and helping on four CPUs |
| **K15.** Every piece of processor state user mode can read or write is saved per thread or trapped | each kernel-mode control register is written from zero plus the enables the architecture binding lists, so a feature whose user-mode access an enable bit controls stays trapped; a thread record saves exactly the enabled state, which the binding lists: the general registers, the user stack pointer, the FP and SIMD registers with their control and status, and the thread-pointer registers, one of which holds the address of the thread's kernel-user page and is read-only in user mode ([Port contract](#port-contract)) | a control register written by read-modify-write; a feature whose user-mode state needs no enable bit | the boot code's audit of the CPU's feature registers; a test domain that writes every register user mode can write and another that checks it never sees the values |
| **K16.** The boot image never changes after validation, and no user mapping reaches its index; only a `SYSTEM` holder slices a system file; no file is read or mapped before its check | its pages are excluded from the direct map and mapped read-only in the kernel; no call writes them, and its capability carries no `WRITE`; the whole image's object has an empty ceiling, so no mapping of it can be made whatever its capability carries (K4), and it is not one of the immutable objects that parent copy-on-write children; `erx_image_slice` covers only whole pages of a run of entries, and refuses a run with a system file unless the capability carries `SYSTEM`, and a slice covers only files whose check passed, every mapping of a file being made from a slice | a direct map that covers the boot image's range; a slice made before its files are checked; a writable mapping; a slice that covers the index; any access in the whole image's ceiling | the kernel-table walk also checks the boot image's range; the flipped-byte cases of [Tests of the boot image](#tests-of-the-boot-image); host tests of the slice arithmetic; a domain test that tries to map the whole image, to make a child of it, to slice a system file without the right, and to map the index |
| **K17.** Every capability is in a table, and enters a table only by that space's own call or its creator's | a message's capabilities move only at the rendezvous, into slots its receiver reserved in its own call, and every other install needs the caller's own table or `CAPS` on the target, which only the space itself and its creator hold, since a space's capability leaves its creator's table with `INSPECT` alone ([Passing capabilities](#passing-capabilities)) | a message or ring format that carries a capability; a pass that fills a slot its receiver did not reserve; a pass that holds capabilities outside every table from one call to the next; an installer that ignores the emptied flag; a pass of a space's capability with more than `INSPECT` | a source check that the table's fill is referenced only from the creation calls, `erx_cap_dup`, `erx_pass_install` and `erx_space_copy`; the pass core's exhaustive host model with timeouts, deaths, closes and emptying; domain tests that a receive with no room receives nothing, that a pass to a space that has just ended drops what it carried, and that a space's capability passed into a sub-space carries `INSPECT` alone |
| **K18.** A stopped space's threads never return to user mode, and its exit record arrives only when none of them can act | every path to user mode passes `erx_return_check`, where a thread of a stopped space dies once its call is finished, no thread is created or started in a stopped space, and the exit record waits until the space's active count, which holds every thread that runs or is preempted inside a call, reaches zero, which each finishing thread reaches on its own CPU, finishing its call at the finishing level above every urgency, within that CPU's finishing share and outside every quota ([Execution model and locking](#execution-model-and-locking), [Threads and faults](#threads-and-faults)) | a path to user mode that skips the check; a thread that runs without entering the count; a call abandoned at a preemption point; a finishing thread throttled by any grant, its own group's or its killer's; a finishing thread below a user urgency, or held past its share; a group of the thread's own path dropped before its last switch, which the accounting still charges | a test that stops a domain whose threads run on every CPU, some inside long calls and deletions, and creates and starts threads while it is stopped, and checks that the exit record comes only after the last of them is dead or asleep and that every deletion it started completed; a test that sets a group's quota to zero while its thread is preempted inside a long range call, then stops the thread's space from a group whose quota is zero as well, and sees the call complete within the share's bound and the exit record come; a test that stops such a space from a thread whose cpuset excludes the dying thread's CPU, then deletes the stopper's thread while the target is preempted inside its call behind a spinner above every user urgency on its CPU, and sees the call complete and the record come; the exhaustive model of the count against concurrent switches; a seeded kill that throttles the thread on its killer's grant, which the finishing model catches as a thread never dying while that grant is zero, and a seeded finishing level placed below a user urgency, which the spinner case catches as a record that never comes |
| **K19.** While a machine lease is held, the machine ends only in a reset | one funnel, `erx_machine_end_effect`, performs every end, the panic path's included, and maps every end to a reset while the kernel's own record of the lease, set at boot step 2, says one is held; the deadline is checked from the kernel's own timer, and the board's watchdog covers a kernel that stops taking interrupts | an end path that bypasses the funnel; a watchdog stopped while a lease is held | the funnel's host tests over every end and lease state; a QEMU test of each end with and without a lease; on each board, a trial that panics, hangs in the kernel with interrupts masked, or calls `halt/0`, each booting the committed slot |
| **K20.** Preemption never runs runtime code: no executor receives an upcall | `erx_vcpu_control` refuses an executor, a thread's class is fixed when it is created, and only an armed thread receives upcalls ([vCPU upcalls](#vcpu-upcalls)) | an arming path without the class check, or a call that changes a thread's class | host tests of the arming rules over every class; a domain test that arming an executor fails with `ERX_ETYPE` |
| **K21.** An object's release happens once, and only once, after the last capability to it has gone | every slot is cleared by `erx_cap_slot_clear` under the object's capability lock, a move hands its count from slot to slot without passing through zero, and the decrement to zero closes the slot list to inserts, so nothing makes a capability after the release ([Objects and capabilities](#objects-and-capabilities)) | a slot cleared without the decrement or outside the object's capability lock; a move split across two operations; a copy inserted after the release; a call that names an object by anything but a capability | the release core's exhaustive host model over closes, moves, deletions and table emptying, with copies and moves whose lookups raced the last close, which checks that every slot is freed once, that no copy follows a release, and that the last close of a deleted object leaves it deleted; a domain test in which a domain passes a gate to its sub-space at a rendezvous, closes its own capability, and sees the gate released only when the sub-space closes it; a test that stops the sub-space and empties its table and sees the release then |
| **K22.** A copy-on-write child never writes a page it does not own, and no device writes a shared page | every user translation comes from `erx_pte_make`, which grants write only for a page its mapping's object owns exclusively, and a child's mapping is populated only with pages the child owns, so no translation anywhere names a page shared by copy-on-write; every fault in a child's mapping, whether the CPU reports a missing translation or a permission fault, goes through the fault decision to `erx_cow_decide`, and only `erx_cow_install` makes a page the child's own, under the child's lock, touching no translation table; the kernel writes a memory object's pages only through `erx_window_write`, which makes a child's page its own through `erx_cow_install` before it writes it; `erx_dma_map` takes only pages its object owns exclusively | a translation built elsewhere; a translation in a child's mapping that names a parent's page; a kernel write into a child's page that skips `erx_cow_install`; a DMA mapping of a parent's page | the funnel's exhaustive host model over every fault, window write, page state and concurrent `erx_mem_own`, and over deletions of the child and unmaps of its mapping racing faults on it, with a seeded fault that releases its space's lock between the copy and the write of the translation, which the model catches as a translation naming a page it has released; the fault decision's model over every mapping kind, page state and access; a hostile test that writes a child's page from two threads while a third reads the parent, and one that maps a child at a thousand addresses in two spaces and writes one page through each, each write taking one bounded part and every alias reading the written page afterwards, with a seeded populate that maps the parent's page for a read, which the host model's check that no translation names a parent's page catches; a test that a child range with an unowned page cannot be DMA-mapped; the build checks on `erx_pte_make` and `erx_cow_install` |
| **K23.** Copy-on-write is one level deep, its parents never change, and every page it can need is reserved at creation | `erx_mem_child` takes only an immutable parent with `CHILD`, which no child carries, and reserves, charges and backs the child's full size; `erx_space_copy` copies a child as a fresh child of the same parent, reserved, charged and backed at its full size; a paged object reserves and backs its whole size at creation, and nothing is evicted | a child of a writable object; a child created with `CHILD`; a copy that makes a child of a child; a write fault that allocates outside a reserve | a host model of the accounting with children; domain tests that a child of a child or of a writable object fails with `ERX_ETYPE`; a domain test that writes every page of a child created at the edge of its budget |
| **K24.** No capability that leaves its table for another space's carries code, device or structural authority, unless that space's creator passes it there | every pass at a rendezvous, every `erx_cap_pass` into a space other than one the caller created, and every copy `erx_space_copy` makes intersects rights with the type's pass set, which the generator requires every type to declare ([Passing capabilities](#passing-capabilities)); the structural types declare none, memory's holds no right to execute, make code, reach a device or fill an object others read, and a JIT object has no `DUP` or `GIVE`; only a space's creator conveys the rest, by `erx_cap_pass` into that space; a fork maps in the child only what its parent had mapped | a pass set that grows; a type without one; a JIT object created with `DUP` or `GIVE`; a copy path that skips the pass set; a pass past the pass set into a space the caller did not create | the generator's checks; a host property test that every planned pass's rights lie within its type's pass set unless its target is a space the caller created; domain tests that try to pass every type with every right, at a rendezvous and into a peer's space; fork tests that the child holds no budget, space, thread, group or JIT object of its parent's and no capability to its parent's copy-on-write children, and that a library its parent mapped stays executable in it |
| **K25.** A capability leaves a table only by its holder's close or move, its space's emptying, or its object's deletion | capabilities are flat: every slot naming an object is an equal entry in the object's slot list, and none depends on another; `erx_cap_slot_clear`, the one function that clears a slot, is called only by `erx_cap_close` on the caller's own slot, by a move at a pass, by `erx_space_clear_caps`, which needs `CAPS` on the space, by the teardown of a deletion, which needs `DESTROY` on the object or on its budget, and by the emptying of a table whose space is released or whose parent is deleted ([Closing and deleting](#closing-and-deleting)) | a call that clears a slot of another table without `CAPS` or `DESTROY`; a close that removes more than its own slot | the chokepoint check on `erx_cap_slot_clear`'s callers; the deletion core's exhaustive host model over copies, moves, closes, deletions and table emptying, which checks that a close removes exactly one slot; a domain test that copies a memory object into three domains and closes the giver's capability, after which the other two still map and read it |
| **K26.** A deleted object is unreachable at once, and its memory faults | a deletion first closes the object, invalidating its existence lock, which the one lookup, every insert function and every taker of the lock refuse; it then drains the object, waiting for the operation that holds the lock, and its teardown removes before the call returns, or for a space before the call that unlinked it returns, everything that attached before the close, but for a dying thread's own part, which the thread runs itself; the record is freed only after a grace period ([Closing and deleting](#closing-and-deleting)); deleting a space deletes every space below it, by a walk that runs on the time of the call that unlinked each, and withdraws an undelivered exit record ([Creating spaces](#creating-spaces)) | a lookup or an insert that skips the check; a space below a deleted one answering a lookup once the walk that unlinked it has ended; a deleted space's exit record left waiting at its gate; an operation that changes an object across a preemption point without its existence lock; a capability, translation, DMA translation, binding or queued thread that survives the teardown; a free before the grace period | the deletion core's exhaustive model, with lookups, attachments and holders of the existence lock racing deletions and releases; the chokepoint checks on the insert functions and on the takers of both locks; a domain test that deletes a gate with senders blocked on it, and a memory object mapped in two spaces and a DMA window, whose next CPU access faults and whose DMA aborts at the IOMMU; a test that deletes a thread inside a long call and finds the call completed, its senders woken with `ERX_EDEAD` and its record freed; a test that destroys a group whose member threads run on every CPU, one of them inside a long call, and finds every member killed, the call completed and the group's record freed once its last member is dead; a test that deletes a space while a thread of another space maps into it and one of its own commits a range, and finds the destroy waiting for both and then detaching every record they added; a hosted ASan test that destroys the budget, and one that destroys the container, between a creation handler's return and the dispatch's installation, on every creation call, a thousand times each, and finds each call returning `ERX_ESTALE` and the record freed once, after its grace period, with a seeded handler that returns its object borrowed, its reference dropped with the lock, under which the installation reaches a freed record, which ASan reports, and a seeded installation that leaves an object it installed no capability to live, which the leak check catches |
| **K27.** A space never outlives its parent | every space but the first names its parent at creation, and nothing changes it; every stop of a space is made by, or starts, one of the two walks, which keep the children whose walk is unfinished first in each parent's list, so every space below a stopped one stops and has its kills posted by every stopper's own walk; a stopped space refuses new children, under the parent's lock; a space's exit record waits until every child's has been posted; a space's destroy runs the deletion walk, which deletes every space below it, or finds that another call's walk owns it, so once those walks have ended no capability in any table keeps a space whose parent is deleted, and a child leaves its parent's list only when its deletion begins; a space's record is freed only after every child's record, so a walk that counts its root and the last space it descended into reads only live records on its way back up ([Creating spaces](#creating-spaces)) | a creation that skips the parent's stopped check; a stop path that does not walk the children; a deletion walk that begins before its root's stop walk is done; a child that leaves its parent's list by anything but its deletion; a capability, or an exit record no one receives, that keeps a space whose parent is deleted once the walk that unlinked it has ended; a stop that waits on another stopper's walk; an exit record posted while a child can still run; a space's record freed while a child's record lives; a counted reference taken through a parent pointer | the stop core's exhaustive host model over creations racing stop walks and deletion walks, which checks that a walk moves a child in the critical section that marks it walked, with a first walker that stops after any part and a second that must finish its work and that a child leaves its list, closed, exactly when its deletion begins; the same model with each deleted space released as soon as no walk counts it and its frees run a round at a time, which checks after every step each space's count of holds, that a record is freed only at zero and that no unfinished walk is on a freed record, with freed records poisoned under AddressSanitizer; a host test that frees a chain as deep as the tree one level per round; the chokepoint check that lists the callers of `erx_space_parent`; a host test in which a child is stopped and deleted, which takes it off its parent's list, a sibling is then stopped, and the parent is then stopped and deleted, which must delete the sibling; a host test in which a kept capability keeps neither a deleted space's record nor its parent's; host tests over the core's exit word, over every order of a destroy with both posts and receipts, in which a record that waits, one posted but not placed, one whose receiver has died and one posted after the deletion began each end dropped and counted; a host test that releases a sub-space of a live parent and then stops the parent; a domain test that stops a domain with three levels of sub-spaces running on every CPU and receives every sub-space's exit record before the domain's; a domain test in which S creates P on a budget another party holds `DESTROY` on and C under P on S's own budget, keeps C's capability, and the budget is destroyed: C's capability answers `ERX_ESTALE`, each of C's and P's records is either taken, C's before P's, if S received it before the deletion began, or counted in the gate's drop count, and the budget's tombstone goes within two grace periods and `ERX_SPACE_DEPTH_MAX` rounds while S still holds the slot; the same with S never receiving, where the tombstone goes all the same and the drop count rises by two; the same with the receiver dead and the gate unbound, and with the gate bound again between the post and the deletion; a domain test in which `erx_space_clear_caps` on a stopped P empties P's table alone, C stays on P's list, and a later destroy of P deletes C |
| **K28.** Every fault reaches the fault gate fixed at its space's creation | a space's fault gate and label are arguments of `erx_space_create` and no call changes them; the upcall state has no flag that diverts a fault, so an armed thread's faults go the same way; a fault record stops the thread and queues at the gate's thread, at most one per thread | a call that changes a fault gate; an upcall for a fault | the call table has no such call; a domain test that arms a thread, sets every bit of its upcall state word, faults it in every exception class, and finds each fault record at the fault gate |
| **K29.** No upcall event is lost | an event for an armed thread that cannot take it at once stays queued at the thread with the pending flag set; `erx_vcpu_step` runs at every trigger, every return to user mode, every wait entry, every start after a stop, every resume, every arming and every disarm, and with events enabled and a delivery queued it enters the upcall at a return, ends a umtx wait with `ERX_EINTR` at its entry, and has a resume enter the upcall again instead of resuming, in one step | a return to user mode, a wait entry, an arming or a resume that leaves events enabled with an event queued | `erx_vcpu_step`'s exhaustive host model over every order of trigger, upcall, resume, wait entry, return from a call, stop, start, arming and disarm; a domain test that triggers between the handler's last check and its resume; a test that triggers during a call's reply phase and sees the upcall at the call's return; a test that queues a delivery before arming and sees the upcall at the arming's return |
| **K30.** No thread of a held space returns to user mode, holds never keep a thread from finishing kernel work, holds compose, and no hold waits for a peer | `erx_return_check` is the only code that acts on a space's holds, which only the space core's pause and resume change, and it decides a death or a stop before a hold, so everything else runs a held space's threads to the boundary; each pause is a hold of its own, named by the ticket it returns, so a session's pauses for its causes, the one it copies under among them, compose, each resume lifts the one it names, and a resume ends the quiesce waits and the copy under that hold alone; a ticket names one hold ever, since it carries the space's pause count, so a resumed ticket is refused and a quiesce or a copy under it ends at its next check even when a later pause has taken the same slot; a pause returns once the interrupts it sent have been taken, and a quiesce waits only for the space's own threads inside calls, since a thread asleep in a wait is not active and what the rest of its call writes is either never read by a copy or a slot, which the copy takes whole, before or after; a quiesce wait ends whenever its condition holds or can no longer hold, at the mark, at the resume of the hold it waits under or at the space's stop ([Threads and faults](#threads-and-faults)) | a path to user mode that skips the check; a second reader of the holds, such as a ready path that keeps a held thread off the CPU; a copy that runs without the mark, or under a hold that is not held; a resume that reads how many holds remain instead of the hold it names; a ticket that is a slot index alone, under which a resume and a new pause between two parts of a copy let the copy go on under the new hold; a pause that returns before its interrupts are taken, or on a kernel entry its baseline counted; a sleeping thread counted as active; a quiesce wait that a resume or a stop leaves asleep; a call that may wait and writes a memory window | the space core's exhaustive host model over pauses, resumes, quiesces, copies, stops, kills, `CONTROL` stops, wakes, preemption and helping, with a seeded resume that leaves the quiescers queued, which the model catches as a wait outliving its hold, and a seeded resume that ends a quiesce only when the last hold goes, which the model catches as a quiesce under a resumed hold left asleep while another hold remains; a test that deletes a thread of a paused space and finds its senders woken with `ERX_EDEAD` before the resume; a test that pauses a space while one of its threads is preempted holding its space's lock and another waits for that lock; a domain test that forks a program whose threads write memory on four CPUs and finds one consistent snapshot in the child; a test that resumes the copy's hold during a copy while a second hold on the source remains, and finds the copy ending with `ERX_EBUSY` at its next part, nothing of the source changed and its threads still held, then resumes the second hold and finds them back in user mode; a test that resumes the copy's hold and takes a new pause on the source between two parts of the copy, and finds the copy ending with `ERX_EBUSY` at its next part and the new hold still held, with a seeded ticket of the slot index alone, under which the copy completes; a test that destroys `from` after a child of a gigabyte has been mostly backed, and finds the destroy returning within one part's bound while the copy's teardown of the child runs on and the child's pages refunded when the copy returns, with a seeded copy that tears the child down before it releases the two spaces' locks, which the destroy's bound catches; a test that replies to a waiting thread of a paused space and finds the reply in its registers when it next runs in user mode; a test that pauses a space whose threads spin in user mode on four CPUs and finds none of them running user code once the pause has returned; a test that pauses a space whose thread waits in a call to a server that never replies, and finds the pause returning at once, the quiesce completing and a copy of the space completing while the call still waits; a test that resumes the hold a quiesce waits under while the quiesce waits for a thread whose group has no quota left, and finds the quiesce returning `ERX_EBUSY` and the thread back in user mode once its group has time, and one that stops that space instead and finds the quiesce returning `ERX_EDEAD` |
| **K31.** The machine runs only while the root task runs: a fault of the root task, its halt outside an ordered shutdown, and a watchdog deadline it misses each end the machine, after a crash record | the first space has no fault gate, so its faults reach `erx_panic`, which writes the crash record and ends through `erx_machine_end_effect`; its exit record has no gate to go to, so a stop of the first space by anything but `erx_machine_end` takes the same path; the watchdog's deadline is checked from the kernel's own timer, which also reloads the board's watchdog for as long as the kernel runs, so a kernel that stops running resets too; only `POWER` on the root resource, which no carved resource carries, pets it; deterministic mode alone turns it off, and release builds refuse deterministic mode ([The root task](#the-root-task), [The watchdog](#the-watchdog)) | an end path that bypasses the funnel; a pet accepted without `POWER`; a deadline the pet of a thread outside the root task could extend; a first space that stops without a record | the watchdog machine's exhaustive host model over pets, ticks, arming and the mode; a QEMU test whose root task stops petting, and one whose root task faults, each finding the crash record on the console and the end the configuration names; the crash record's checks fuzzed on the host; on each board, a root task that stops petting, which boots again with the record handed to the new root task |
| **K32.** A guarantee is never taken from the budget it was carved for, a budget borrows only its ancestors' room, and a domain's memory is walled from every other's | a charge beyond a budget's guarantee is counted, through `erx_budget_adjust`, as `lent` at every ancestor it passes until one's guarantee absorbs it, and every ancestor's `carved`, the sum of its children's guarantees, is part of the spending its cap and guarantee are checked against, so lending never reaches what a parent guarantees to another child, and a parent's shrink revokes no child's guarantee, since a child's charge within it raises nothing the parent counts; the chain is held under the budgets' locks, descendant first, and applied whole, so no interleaving sees borrowed memory uncounted; a wall, a budget carved with cap fixed equal to its guarantee, takes no new charge beyond its guarantee, so every charge's chain ends at the first wall, admitted within the guarantee or refused, and a wall borrows only the excess its carver's own shrink left above the guarantee, which falls as its tree frees; the domain library carves every domain's budget as a wall, so a domain's charge is admitted or refused at its own budget alone, nothing of a domain's is ever counted against another domain's, and against its principal's room only what the principal's policy moved there by a shrink; a dead budget's spending is counted in its nearest live ancestor's `used` from its close, and every refund of what it held passes there, so what is charged to the machine is the sum of `used` over the budgets that are live and whose every ancestor is live; a charge ends when memory is released, not when it is freed, so no refusal depends on the reaper's timing or on what is carved or destroyed meanwhile, and a refusal says only that the tree's charges reach the cap; resizing needs `DESTROY`, which carving places in the carver's slot (K2) and which reaches another space only by the carver's own pass, and the domain library's grant table passes no budget with it ([Budgets](#budgets)) | a counter changed outside the chain; a chain applied one level at a time; a check of the cap or the guarantee that leaves `carved` or `lent` out; a domain budget carved elastic; a wall whose cap a resize moves away from its guarantee; a refund of a dead budget's applied at the dead budget alone, or a close that moves less than its spending; a page freed without its refund, or a refund that waits for the free; a grant-table row that passes a budget with `DESTROY` to a domain | the host model of the accounting over random carves of both kinds, charges, refunds, resizes, destroys, reaper steps and watches on trees `ERX_BUDGET_DEPTH_MAX` levels deep, which checks after every operation that no charge took a live budget's spending above its cap, that a budget whose cap a resize set beneath its spending is refused every charge that would raise its spending while a child's charge within its own guarantee is admitted, that a wall's cap equals its guarantee and it borrows exactly what a shrink left above the guarantee and nothing after its spending falls beneath it, that every `lent` is the sum of its live children's borrowing and every `carved` the sum of their guarantees, that the sum of `used` over the budgets that are live and whose every ancestor is live is what is charged, between every two close steps of nested destroys, that pages held by reserves plus pages in backings' hands plus released plus free is the root's guarantee after every operation, that every reserve's pool holds a page for every promise not in use between calls, and that a charge is refused only when the tree's charges reach the cap, whatever is released and not yet freed, with seeded failures that apply a chain one level at a time, forget `lent` at a close, leave `carved` out of the cap check, refund a dead budget's page at the dead budget alone, count a dead or doomed budget's `used` toward the machine, refund a page only at its free, and free a page without its refund, each of which the model catches; the same model under TSan with charges, releases, backings, resizes, destroys, carves of child budgets and reaper steps racing on four threads, one of which releases and charges without pause while another carves and destroys budgets, and finds every admitted charge backed, no part of a backing waiting longer than two grace periods, with a seeded release that refunds before it appends, under which a backing finds neither a free nor a released page; the domain library's host test that every budget it carves is a wall and that no row of its grant table passes a budget with `DESTROY`, with a seeded plan that carves one elastic and a seeded row that keeps the right; a domain test in which a program borrows until its session's pool is full, is refused with `ERX_ENOMEM`, and its sibling then commits all of its own guarantee and the session all of its own half, both succeeding, with a seeded chain that skips `carved`, under which the sibling's commit fails; a domain test in which two programs borrow from a full pool, one releases a gigabyte and the other commits a gigabyte at once and touches every page of it, which succeeds with no idle reaper running, the commit taking the released pages off the list at most 64 per part and its touches taking nothing from the allocator, with a seeded release that refunds only at the free, under which the commit fails with `ERX_ENOMEM`; a domain test in which one program of a full pool ends, its budget destroyed with its records still in their grace periods, and a sibling at once commits what the first held, which succeeds with no idle reaper running, with a seeded teardown that releases its pages only at its put, under which the commit fails with `ERX_ENOMEM`; a domain test in which a sub-space budget is destroyed while its sibling's charge is refused, and the sibling's retry succeeds as the destroy's walk releases, before the destroy returns and with no idle reaper running; a domain test in which a program at its cap destroys a thousand gates and creates a thousand at once, which is refused with `ERX_ENOMEM` while the destroyed records wait and admitted once their grace period and the reap deadlines their backlog needs, one per 64 records queued on a CPU, have passed with every CPU busy in user mode, and which, with a call of another domain parked holding one of the gates counted across the destroys, is admitted for all but the records of one cache page until that call runs, with a seeded cache that releases a page while a record in it waits out its grace period, which ASan on the hosted kernel catches, a seeded reap deadline that is never armed, under which the creation stays refused on the busy CPUs, and a seeded deadline that runs one step and does not re-arm, under which it stays refused past the bound, each of which the test catches; a test that destroys a watched budget while passes holding the IRQ object's capability lock run on the other CPUs, under the debug lock-order check, with a seeded teardown that detaches the watch under the budget's capability lock, which the check catches; a domain test that a holder's `erx_budget_resize` on its own budget fails with `ERX_ERIGHTS`, that a carver grows and shrinks a child's guarantee and cap, the parent's counters following, that a shrink below the spending leaves the child refused until it frees while a grandchild's charge within its guarantee is admitted, and that a wall resized to a cap above its guarantee fails with `ERX_EINVAL`; a test that a watch triggers once at its threshold and not again until re-armed, that arming at or above the threshold triggers at once, that arming a second budget with the same IRQ object fails with `ERX_EBUSY`, and that destroying the IRQ object leaves the budget unarmed, with a seeded watch that fires on every adjustment, which the test catches; a test that destroys a borrowing budget and finds the parent's `lent` and `carved` back at their baselines when the destroy returns, with no idle reaper running |
| **K33.** A waiting thread holds nothing across its sleep, and one function completes every wait | a call sleeps only through the wait funnel, which the generated dispatch reaches after the handler has returned every lock and every counted reference and stored the wait's inputs in the wait record; the waker calls `erx_wait_complete`, the one function that turns a wait's outcome into result registers and runs the return check, so the woken thread's frames carry no work, and a wake path may resume it straight to user mode ([Execution model and locking](#execution-model-and-locking)) | a lock or counted reference held into the sleep; a result translated after the wake on the thread's own frames; a wake path that readies a thread without the completion | debug and host builds count each thread's held locks and counted references and assert both zero at the funnel's sleep, with a seeded wait that keeps a reference failing the hosted suite; `erx_wait_complete` referenced from every wake path and nowhere else, by relocation, with a seeded wake that readies the thread directly failing the check; the exhaustive model of the wait funnel over every order of sleep, wake, deadline and stop |

The scheduler's invariants S1 to S8 are in
[design-scheduler.md](design-scheduler.md#invariants).

## Data model

### Typed values

Values that must not be mixed have distinct one-member types, so mixing
them does not compile ([style.md](style.md#names-types-and-declarations)),
and each conversion is a named function that checks what it can:

| Type | What it holds | Converted by |
| --- | --- | --- |
| `erx_pa_t` | a physical address | `erx_pa_to_kva`, which asserts that the address lies in the direct map |
| `erx_kva_t` | a kernel virtual address | `erx_kva_to_pa`, for the direct map |
| `erx_uvpn_t` | a user page number: what mapping records, range calls and the fault path use | `erx_uvpn_of_far`, from a fault address; none to a pointer, so the virtual-memory code never accesses what it maps through the user half (K7) |
| `erx_uword_t` | the address of an aligned 32-bit word in the caller's space, which a umtx call resolves to its key | `erx_uword_load`, the architecture layer's walk of the space's translation tables, which yields a physical page that the direct map covers or `ERX_EFAULT`; none to a pointer (K7) |
| `erx_window_t` | a memory window: a memory object a capability named, a byte offset and a length, checked against the object's size | the generated decoder; only `erx_window_read` and `erx_window_write` reach its bytes (K7) |
| `erx_iova_t` | an I/O virtual address in a DMA window | nothing: only the window's mapping calls take it |
| `erx_pfn_t` | a physical page number | `erx_pfn_to_pa`, and `erx_pa_to_pfn`, which asserts page alignment |
| `erx_mmio_t` | the kernel virtual base of a device's registers | nothing: only generated register accessors take it |
| `erx_pack_off_t` | an offset into the boot image | the validator's bounds-checked readers |
| `erx_cap_t` | a capability value: generation and slot index | `erx_cap_lookup` alone |
| `erx_slot_t` | a slot index inside one capability table | nothing outside `kernel/core/cap.c` |
| `erx_npages_t` | a count of pages | `erx_npages_bytes`, with checked multiplication |
| `erx_time_t` | nanoseconds of the monotonic clock | `erx_time_from_counter`, with a 128-bit product |

Byte counts stay plain integers named for what they count (`size`, `len`,
`bytes`); every count of pages is `erx_npages_t`.

### Objects and capabilities

A **kernel object** is something the kernel allocates and others name
through capabilities:

```c
typedef enum erx_ktype {
	ERX_K_BUDGET = 1,	/* accounting for memory: Fiasco's factory and quota */
	ERX_K_SPACE,		/* an address space, its capability table, its parent */
	ERX_K_THREAD,		/* a thread of a space, with its kernel stack and UTCB */
	ERX_K_GROUP,		/* CPU accounting and grant (design-scheduler.md) */
	ERX_K_MEMORY,		/* shared, contiguous, physical, paged or child memory */
	ERX_K_GATE,		/* an IPC gate, bound to one thread */
	ERX_K_IRQ,		/* a doorbell: software, an interrupt line or an MSI */
	ERX_K_RESOURCE,		/* authority over device ranges, lines and streams */
	ERX_K_DMA,		/* one DMA window behind the IOMMU */
	ERX_K_CONSTRUCTION	/* an object being made: owns its pages until
				 * it is published; never named by a capability */
} erx_ktype_t;

typedef struct erx_object {
	erx_ktype_t	 type;
	_Atomic uint32_t state;		/* ERX_OBJ_LIVE; ERX_OBJ_RELEASED when its
					 * last capability goes while it is live;
					 * never back; a closed object reads as
					 * ERX_OBJ_DELETED */
	_Atomic uint32_t refs;		/* its own until its put; threads that
					 * keep it across a preemption point,
					 * never across a wait (K33) */
	uint32_t	 ncaps;		/* slots naming it; reaching 0 releases it */
	erx_hlock_t	 lock;		/* the capability lock: its slot list,
					 * ncaps, state, and every slot that
					 * names it, as in Fiasco */
	erx_hlock_t	 existence;	/* the existence lock: held by an
					 * operation that changes it across
					 * preemption points; invalidated when
					 * its destroy closes it, then waited
					 * for, as in Fiasco */
	erx_cap_slot_t	*att_slots;	/* the slots that name it, in no order */
	erx_rcu_item_t	 rcu;		/* queues its put behind a grace period */
	erx_budget_t	*budget;	/* pays for this object; fixed */
	erx_dlink_t	 in_budget;	/* on its budget's att_charged until freed */
	uint64_t	 oid;		/* unique for the boot; correlation, never authority */
	char		 name[16];	/* ASCII; may be empty */
} erx_object_t;
```

`ncaps` counts the capability slots that name the object. `refs` counts
the object's own reference, held from its creation until its put, and
the references threads hold, which are of three kinds and never a
call's across a wait (K33): the references a thread holds for its
lifetime, on every group of its path, at most eight, from its creation
until its last switch, so a destroyed group's record lives until its
killed members are dead; the reference a call takes before it works
through an object in parts across preemption points, a range call's or
an existence lock's taker's, dropped before any wait; and the reference
a posted delivery, an exit record's or an IRQ object's, holds on its
object until the record is taken or withdrawn, and a space's deletion
withdraws its exit record, a withdrawal on its way to a CPU holding a
reference of its own. A sender blocked on a
gate holds none: it is linked on the gate's `att_blocked` list, which
the gate's teardown empties, and starts its send over from its
capability when it wakes ([Execution model and
locking](#execution-model-and-locking)). A killed thread, a stopped
space's or a destroyed group's member, finishes its call at the
finishing level, and its time is added, for the accounting alone, to
the `finishing_ns` of its own path, which it holds until its last
switch ([Execution model and locking](#execution-model-and-locking),
[design-scheduler.md](design-scheduler.md#charging-and-quota)). A
capability lookup takes no reference ([Execution model and
locking](#execution-model-and-locking)). Objects never hold counted
references to each other: every pointer from one object to another is an
attachment of its target (below), which the target's teardown removes,
so destroying an object leaves nothing that points at it, and the death
of a budget frees what it paid for without waiting on any other object
([Budgets](#budgets)). An object is **released** when its last capability
goes, whatever removed it (**The release rule** in [Closing and
deleting](#closing-and-deleting)): every type but memory and groups is
then destroyed, as if deleted. A memory object lives on while a mapping or
a copy-on-write child of it remains, and a group while it has member
threads or child groups, and each is destroyed when the last of those goes
or when it is deleted. **Destroying** an object, by a deletion, by the
destruction of its budget or after its release, closes it, drains it and
runs its type's teardown in bounded parts (a space stops, its table is
emptied, its mapping records leave their objects and the spaces below it
are deleted, a thread dies and
unbinds what was bound to it, a gate is unbound and the senders blocked on
it are woken, an IRQ object is unbound and detached from its line and
leaves one last delivery at its target, a memory object's mappings are
removed and its copy-on-write children deleted, a group's child groups
are destroyed, its member threads killed, its IRQ objects unbound and the
deliveries waiting on its ready list withdrawn,
a budget deletes every object charged to it), then queues the put of its
own reference behind an RCU grace period ([Closing and
deleting](#closing-and-deleting)). The teardown releases the pages the
object held, whose charge ends there; when the last counted reference
goes, the record is freed, a space's once every child's record has been
([The reaper](#the-reaper)). No destructor runs under a
caller's lock, none calls another, and destroying a chain of objects is a
loop. The object id is the image of a 64-bit creation counter under a
keyed permutation, a four-round Feistel network keyed at boot from the
entropy generator (with a fixed key in deterministic mode), so object ids
are unique for the boot and say nothing about how many objects anyone
created; inspection reports it so tools can relate capabilities in
different tables to one object, and no call accepts it as authority. The
creation counter never wraps and no id is reused within a boot, including
after an object is freed; creation fails with `ERX_ELIMIT` before
exhaustion could repeat an id. Encodings reserved by the ABI, including
zero, are skipped without reusing their counter values. An object's id can
also correlate a kernel-authenticated fault with an admitted mapping. That
use does not depend on the id being secret or unpredictable, and accepts
no caller-written id as proof of origin.

An object's life, and the verbs this document uses for each step:

```text
          last capability goes
  LIVE ---------------------------------------------> RELEASED
   |                                                     |
   | erx_object_destroy, with DESTROY,                   | at once; memory once
   | or its budget's destruction                         | its last mapping or
   |                                                     | child goes;
   v                                                     | a group once its last
  DELETED <----------------------------------------------+ member or child goes
   |   closed: its existence lock is invalid, so nothing attaches and
   |   no operation begins; its last capability may go during the
   |   teardown, and the object stays DELETED
   |
   | drained, torn down in bounded parts, put after an RCU grace period
   v
  freed once the last counted reference goes, a space once every child's
  record has been too; its pages were released
  by the teardown
```

| Verb | What happens | Who does it |
| --- | --- | --- |
| close | one capability leaves a table | `erx_cap_close`, a move's source slot, emptying a table |
| release | the object's last capability goes, whatever removed it: a live object becomes `RELEASED` and is destroyed, memory and groups once their mappings, children and members are gone; a deleted object stays `DELETED`, its deletion's teardown under way | the slot clear that takes `ncaps` to zero |
| delete | the object is destroyed at once, whoever else holds it | `erx_object_destroy`, with `DESTROY`, the destruction of the budget that pays for it, or for a space the deletion of its parent |
| destroy | the object is closed, by invalidating its existence lock, and drained, by waiting for the operation that holds that lock; then its type's teardown runs in bounded parts, and its put is queued | a deletion, or the release, or for a released memory object or group the last mapping, child or member going; the first to close the object goes on, and a second destroys nothing; a deletion walk that unlinks a space runs that space's teardown and put, whoever closed it, and the destroy that closed it stops at its begin (**Who owns a deletion** in [Creating spaces](#creating-spaces)) |
| put | the object's own counted reference is dropped, after an RCU grace period | the grace period's callback |
| free | the record's slot returns to its budget's cache, and the cache page is released, its charge ending, once it holds no record; the object's pages were released by its teardown | the reaper's record free, run by the put or by the drop of the last counted reference, whichever comes last, and for a space with a child's record not yet freed, by the free of the last such record ([Creating spaces](#creating-spaces)) |

Whatever outside an object attaches to it, another object or a thread,
does so through an **attachment field** of the object's record, a field
whose name begins with `att_`: an object's slot list; a budget's list of
the objects charged to it; a memory object's reverse map of its CPU and
DMA mappings, its list of umtx word queues and its list of copy-on-write
children; a space's or a DMA window's mapping records, each of which is
also on its memory object's reverse map; a space's children and threads;
the copies waiting for a space's threads to quiesce; the spaces whose
fault gate a gate is; the threads blocked on an unbound gate; the gates
and IRQ objects bound to a thread, and the senders and deliveries queued
at it; the budget an IRQ object is the watch of; and a group's member
threads and child groups, the IRQ objects bound to it, the executors
parked in it and the deliveries on its ready list. Each attachment field
has one insert function, all of them in
`kernel/core/attach.c`, and each type's teardown walks every attachment
field its record declares, which a source check verifies field by field,
so a field added to a record without its insert function and its teardown
fails the build; the same check refuses a field of an object record that
points to another object and is not the holder's link in one of its
target's attachment fields ([Execution model and
locking](#execution-model-and-locking)):

```c
/*
 * An object a lookup returned, valid only until its thread's next
 * preemption point of any kind.  The thread's count of preemption points
 * travels with it; every point, an explicit one or taking a helping lock,
 * advances the count; and debug and host builds check it at every use, so
 * a pointer kept across a point fails in tests whatever the timing.
 */
typedef struct erx_uref {
	erx_object_t	*object;
	uint32_t	 epoch;		/* the thread's count at the lookup */
} erx_uref_t;

erx_object_t	*erx_uref_get(erx_uref_t ref);		/* checks the epoch */
erx_object_t	*erx_object_ref(erx_uref_t ref);	/* counted; checks it */
void		 erx_object_put(erx_object_t *object);

/*
 * Take the object's capability lock as Fiasco's lock_obj does: with
 * interrupts masked, check that cap still names the object, try the lock,
 * and after every help look cap up again before touching the object or
 * its lock; return the locked object, or ERX_ESTALE once cap no longer
 * names it.  It takes no reference: a slot names the object, and no slot
 * is cleared without this lock, so the locked object stays allocated.
 * erx_object_lock takes the capability lock of an object the caller holds
 * counted.  The only ways to take a capability lock; erx_object_unlock
 * releases it.
 */
erx_status_t	erx_object_lock_cap(erx_cap_table_t *table, erx_cap_t cap,
		    erx_ktype_t type, erx_rights_t required,
		    erx_object_t **objp);
void		erx_object_lock(erx_object_t *object);
void		erx_object_unlock(erx_object_t *object);

/*
 * Turn a borrowed pointer into a counted reference, then take the
 * object's existence lock, which may help its holder and so pass a
 * preemption point; return ERX_ESTALE, dropping the reference, once the
 * object is closed.  Fiasco's callers take a Ref_ptr first for the same
 * reason (task.cpp).  The only way to take an existence lock;
 * erx_object_unlock_existence releases the lock and the reference.
 */
erx_status_t	erx_object_lock_existence(erx_uref_t ref,
		    erx_object_t **objp);
void		erx_object_unlock_existence(erx_object_t *object);

/*
 * The same for two objects, as Fiasco's Lock_guard_2 takes two tasks'
 * after counting both with Ref_ptr (task.cpp): count both borrowed
 * pointers while no lock is held, then take the two locks in address
 * order, so neither pointer crosses the first lock's helping uncounted;
 * ERX_ESTALE, dropping both references, once either object is closed.
 * Two references to one object fail with ERX_EINVAL, dropping both, before
 * any lock: the second take would help its own holder, and no call that
 * holds two existence locks has a meaning on one object.
 */
erx_status_t	erx_object_lock_existence2(erx_uref_t a, erx_uref_t b,
		    erx_object_t **ap, erx_object_t **bp);

/*
 * Take the existence lock of an object the caller already holds counted,
 * as a copy of a space does after its wait; ERX_ESTALE, keeping the
 * reference, once the object is closed.  Two are taken in address order.
 */
erx_status_t	erx_object_lock_counted_existence(erx_object_t *object);

/*
 * Take the existence lock of a record only the caller can reach, a
 * construction record or an object not yet published, which the caller
 * holds counted from erx_kalloc: the lock is free, which debug builds
 * assert, so the take never helps and never waits, and it stands
 * outside the count and the address order of the waited takes.  The
 * unlock releases the lock alone; the caller's reference is the
 * caller's to pass on or drop.
 */
void		erx_object_lock_fresh_existence(erx_object_t *object);
void		erx_object_unlock_fresh_existence(erx_object_t *object);

/*
 * The object's state: ERX_OBJ_DELETED once a destroy has closed it, by
 * invalidating its existence lock, and otherwise its state word.  Every
 * insert function in kernel/core/attach.c reads it under the lock that
 * guards its field and links nothing, returning ERX_ESTALE, when the
 * slot list's insert finds anything but LIVE, so no capability is made to
 * a released or closed object, or another insert finds DELETED.
 * erx_cap_slot_clear writes the state word, from LIVE to RELEASED only,
 * and only the deletion core closes an object.
 */
uint32_t	erx_object_state(const erx_object_t *object);
```

A **capability table** belongs to a space. It is a directory of pages of 64
slots each that grows a page at a time and never moves a slot:

```c
typedef struct erx_cap {
	uint64_t	value;		/* bits 0-23 slot index, 24-63 generation */
} erx_cap_t;

typedef struct erx_cap_slot {
	_Atomic(erx_object_t *) object;	/* NULL while free or reserved */
	erx_cap_table_t	     *table;	/* the table it belongs to; fixed */
	_Atomic uint64_t      generation; /* low 40 bits used */
	_Atomic uint32_t      rights;	/* the bits of an erx_rights_t */
	_Atomic uint64_t      seq;	/* monotonic; odd while a writer changes the slot */
	struct erx_cap_slot  *prev;	/* in its object's slot list, under the */
	struct erx_cap_slot  *next;	/* object's lock; next also links the free list */
} erx_cap_slot_t;		/* padded to 64 bytes, one cache line */

/* Private to the core: kernel/core/cap_impl.h and cap_slot_impl.h. */
typedef struct erx_cap_table {
	erx_spinlock_t	   lock;	/* writers of every slot's fields but the
					 * list links; the free list; growth */
	erx_cap_slot_t **pages;	/* directory sized for limit / 64 pages */
	erx_budget_t	  *budget;	/* pays for the pages: the space's */
	uint32_t	   capacity;	/* slots in allocated pages */
	uint32_t	   limit;	/* the space's capability limit */
	erx_cap_slot_t	  *free_head;
	erx_cap_slot_t	  *free_tail;
	bool		   emptied;	/* set by erx_space_clear_caps or the space's
					 * deletion; nothing is installed after it */
} erx_cap_table_t;

/*
 * Resolve a capability of this table: bounds, generation, type, rights,
 * the object's state and its budget's, in that order, reading the slot
 * under its sequence count; takes no lock and no reference.  The object
 * returned is valid until the caller's next preemption point or wait,
 * helping included, since freeing waits for a grace period; its epoch says
 * so.  Every call that names an object comes through here.
 */
erx_status_t	erx_cap_lookup(erx_cap_table_t *table,
		    erx_cap_t cap, erx_ktype_t type,
		    erx_rights_t required, erx_uref_t *refp);
```

A slot is free, **reserved** for a pass that a receive of the space's own
awaits, or live; a reserved slot is off the free list and named by no
value until the pass fills it or the receive releases it
([Passing capabilities](#passing-capabilities)).
Capability value 0 is never valid: slot 0 is never issued.

**Reserved values.** `ERX_CAP_SELF` is `0xffffff` and `ERX_CAP_SELF_THREAD`
is `0xfffffe`: generation 0, with slot bits above `ERX_CAPS_MAX`, the most
slots any table has, so no slot can ever bear either and neither can collide
with a capability a table issued. The one lookup resolves them, so no second
lookup path exists. `erx_cap_lookup` reads the calling thread's space and
thread, and passes them to the capability core's `erx_cap_read` as a pure
argument, `erx_cap_self_t`, which is null for a read of another space's table,
where both values are stale. With it, `erx_cap_read` reads the value as a live
slot that holds that object with the rights of the kinds `reserved_space`
and `reserved_thread` (`MAP`, `THREADS`, `CAPS` and `STOP`; `CONFIGURE`), and the
type and rights checks that follow are the same as for any capability. Neither
kind carries `INSPECT`, `DUP`, `GIVE` or `DESTROY`, so no call copies, passes,
inspects or deletes through them, and since they name no slot, their view's
slot is 0, a pass plan refuses one, and a close of either is `ERX_ESTALE`. Any other value with slot
bits above a table's limit is stale. Whether the object is
closing is `erx_cap_lookup`'s own check, as for every other capability.

**Reading a slot without a lock.** A lookup reads a slot under its
sequence count, and every access to the slot's object, generation, rights
and sequence count is atomic, so a reader that races a writer reads old or
new values, never a torn one, and the program has no data race in C17's
sense. The writer, holding the table's lock, stores the count plus one
with relaxed order, which makes it odd, stores each field it changes with
release order, and stores the count plus two with release order. The
reader loads the count with acquire order and starts again while it is
odd, loads the fields with acquire order, then loads the count again, and
uses its copy only if the count is unchanged. A field the reader loads
that a writer stored makes that writer's odd count visible to the second
load, which cannot move before the field loads, so a copy the reader
accepts is one state of the slot. This is the sequence lock that H.-J.
Boehm analyses for the C11 memory model ("Can seqlocks get along with
programming language memory models?", MSPC 2012), with acquire loads of
the fields in place of a fence: ThreadSanitizer models acquire and release
accesses directly, while its support for standalone fences is partial. It
is the rule every lock-free reader of the kernel follows
([Sequence-counted records](#sequence-counted-records)). The common path
makes no atomic read-modify-write, and only `kernel/core/cap.c` touches a
slot's fields (K1): the slot's record is defined only in a generated
private header that only the core and its host tests include. A table's
record is the core's alone too, defined only in `kernel/core/cap_impl.h`:
the space that owns a table sizes it with `erx_cap_table_size` and hands
the core its directory and each page as untyped storage, which the core
owns from then on, so no other code writes a table's counts, its free
list or its emptied flag, or puts a page of slots of its own in the
directory (B4).

The sequence count belongs to the physical slot and is never reset when
the slot is cleared, reserved or reused. It follows the retirement rule
of [Sequence-counted records](#sequence-counted-records): a saturated
slot is permanently unavailable, and lookup treats its terminal count as
`ERX_ESTALE`, never as a writer to wait for. Retirement of a live slot
clears its capability through `erx_cap_slot_clear`, with the normal
detachment and release accounting; it never returns to the free list.

**One lock over a slot's life.** As in Fiasco, where an object's lock over
its slot list also protects every slot that points to the object
(`kobject.cpp`), every change to a slot is made under its object's
capability lock, with the table's lock taken inside it for the table's own
fields. Clearing a slot goes through one function, `erx_cap_slot_clear`,
which holds the capability lock throughout: under it and the table's lock
it checks that the slot still names the object at the generation its
caller looked up, makes the slot's sequence count odd, unlinks the slot
from the object's list, decrements `ncaps`, advances the generation,
appends the slot to the free list and makes the count even. When `ncaps`
reaches zero it reports the release to its caller, and sets the object's
state word to `ERX_OBJ_RELEASED` before it drops the capability lock. The
release destroys the object, for every type but memory and groups, a
destroy that goes on only if no deletion closed the object first, so the
release of an object under deletion destroys nothing, its deletion's
teardown being under way (K21). Every other operation on a slot it names,
a copy, a pass, a move or a close, makes the same check under both
locks and fails with `ERX_ESTALE` when it fails, so no operation acts on a
slot that another is changing, no slot is freed twice, and no capability
is made to an object after its release, since the slot list's insert
refuses an object that is not live. The free list is FIFO, so generations
advance evenly across slots; a slot whose generation would reach 2^40 - 1
is retired instead of freed, so no value is ever issued twice by one
table. Capability values are not randomised: the generation alone stops
reuse, and deterministic values keep transcripts reproducible. A space's
capability limit is set when it is created, at most `ERX_CAPS_MAX` (2^20);
an ERTS domain needs a few dozen.

**Slot lists.** Every capability to an object is a slot on that object's
list, in no order, as in Fiasco's object space, where each object keeps
the list of the slots that name it: a creation starts the list, a copy
adds a slot, a move puts the receiver's slot in the place of the
sender's, and a close unlinks one slot. No capability is derived from
another, so closing one never touches the rest, and only a deletion walks
the whole list ([Closing and deleting](#closing-and-deleting)). The list
costs no allocation beyond the slots.

**Labels.** A gate carries the label its binder gave it, and an IRQ object
the label of its binding; a receiver learns the label of whatever
delivered to it, so a server tells its clients apart by the gates it bound
for them, as in Fiasco ([IPC gates](#ipc-gates)). Capabilities carry no
label of their own.

### Rights

Capability rights are distinct from the rights of a domain's exports
(`send`, `link`, `exit`, `spawn`,
[design-domains.md](design-domains.md#exports)), which each runtime keeps
in a table of its own; the ABI file defines both sets.

| Right | Meaning |
| --- | --- |
| `DUP` | the capability may be copied: by `erx_cap_dup`, by a pass that copies, and into a forked child |
| `GIVE` | the holder may make the capability leave its space: pass it at a rendezvous, or from its own table with `erx_cap_pass`; `erx_cap_pass` from a space other than the caller's, which needs `CAPS` on it, needs no `GIVE` ([Passing capabilities](#passing-capabilities)), and neither does a fork's copy, since a forked child is a copy of the same program |
| `DESTROY` | delete the object for every holder; on a budget, delete every object charged to it ([Closing and deleting](#closing-and-deleting), [Budgets](#budgets)) |
| `INSPECT` | `erx_object_info` topics beyond the basic one; for a space, bounded descendant topology/state/charges, with detailed child queries requiring that child's authority |
| `READ`, `WRITE`, `EXEC` | map readable, writable, executable |
| `MAP` | map the object at all; for a space, act on its mappings |
| `JIT` | map one memory object writable at one address and executable at another, in a JIT space |
| `PHYS` | learn the device address of contiguous memory, for unconfined DMA |
| `SUPPLY` | manage a memory object: fill a paged object, seal a paged or shared object, grow a shared object and report its stores ([Virtual memory](#virtual-memory)); no pass between peers carries it, only a creator's pass into a space it created ([Passing capabilities](#passing-capabilities)) |
| `CHILD` | make copy-on-write children of an immutable memory object |
| `CODE` | authorise creating a paged object whose pages may be executed, and a JIT space from a space that is not one |
| `ALLOC` | create objects paid for by this budget |
| `SPACES` | create spaces paid for by this budget |
| `CARVE` | create child budgets; carve resources; slice the boot image |
| `SYSTEM` | slice files of the system release from the boot image |
| `THREADS` | create threads in a space |
| `CAPS` | pass capabilities into and out of a space's table with `erx_cap_pass`, past the pass sets into a space other than the holder's own, name it as a new space's parent, and empty it once the space is stopped |
| `STOP` | stop every thread of a space, and of every space below it, at once and for good |
| `CONTROL` | start, stop, read and write the registers of a thread |
| `CONFIGURE` | change a thread's urgency or affinity, arm it for upcalls, or bind a gate or an IRQ object to it; set a group's grant or a hardware line's routing |
| `ATTACH`, `SIGNAL` | a group's ([design-scheduler.md](design-scheduler.md#kernel-calls)): create threads in it, and bind an IRQ object to it |
| `CALL` | send and call through a gate |
| `SERVE` | bind a gate to a thread with a label, and name it as a space's fault gate |
| `TRIGGER` | trigger an IRQ object |
| `BIND`, `ACK` | bind an IRQ object to a thread or a group, and a DMA window's faults to an IRQ object; unmask a line or an MSI while no delivery of it waits or is owed |
| `POWER` | end the machine: power it off or reset it; pet the watchdog |
| `TRACE` | read the kernel's trace rings and its log |
| `ENTROPY` | credit bytes added to the entropy generator |

Each object type has a closed set of rights it can carry, a default set
that creating it returns, and a **pass set**, the rights a capability of
the type keeps when it passes to another space or a fork copies it into
the child, all declared in the ABI file; a type whose pass set is empty
never passes and is never copied by a fork:

| Type | Rights it can carry | Created with | Passes with |
| --- | --- | --- | --- |
| budget | `ALLOC`, `SPACES`, `CODE`, `CARVE`, `INSPECT`, `DUP`, `GIVE`, `DESTROY` | all of them, within the rights of the capability carved through, so `CODE` only through a capability that carries it, as the root budget's does, and `DESTROY` always, so the carver can delete what it carved; the root budget's capability carries no `DESTROY` | never |
| space | `MAP`, `THREADS`, `CAPS`, `STOP`, `INSPECT`, `DUP`, `GIVE`, `DESTROY` | all of them | never |
| thread | `CONTROL`, `CONFIGURE`, `INSPECT`, `DUP`, `GIVE`, `DESTROY` | all of them | never |
| group | `CONFIGURE`, `ATTACH`, `SIGNAL`, `INSPECT`, `DUP`, `GIVE`, `DESTROY` | all of them | never |
| memory | `READ`, `WRITE`, `EXEC`, `MAP`, `JIT`, `PHYS`, `SUPPLY`, `CHILD`, `CARVE`, `SYSTEM`, `INSPECT`, `DUP`, `GIVE`, `DESTROY` | by kind, in the table below | `READ`, `WRITE`, `MAP`, `CHILD`, `INSPECT`, `DUP`, `GIVE` |
| gate | `CALL`, `SERVE`, `CONFIGURE`, `INSPECT`, `DUP`, `GIVE`, `DESTROY` | all of them | `CALL`, `SERVE`, `INSPECT`, `DUP`, `GIVE` |
| IRQ object | `TRIGGER`, `BIND`, `ACK`, `CONFIGURE`, `INSPECT`, `DUP`, `GIVE`, `DESTROY` | all of them; `ACK` and `CONFIGURE` only on a hardware line or an MSI | `TRIGGER`, `INSPECT`, `DUP`, `GIVE` |
| resource | `CARVE`, `POWER`, `TRACE`, `ENTROPY`, `INSPECT`, `DUP`, `GIVE` | `CARVE`, `INSPECT`, `DUP`, `GIVE`; the root resource also `POWER`, `TRACE` and `ENTROPY`, which no carved resource carries | never |
| DMA window | `MAP`, `BIND`, `INSPECT`, `DUP`, `GIVE`, `DESTROY` | all of them | never |

A memory object is created with rights that depend on its kind, and
`CHILD` makes children only once the object is immutable:

| Kind of memory | Created with |
| --- | --- |
| shared memory | `READ`, `WRITE`, `MAP`, `SUPPLY`, `CHILD`, `INSPECT`, `DUP`, `GIVE`, `DESTROY` |
| physical memory | `READ`, `WRITE`, `MAP`, `CHILD`, `INSPECT`, `DUP`, `GIVE`, `DESTROY` |
| contiguous memory | as physical memory, plus `PHYS` |
| a JIT object | `READ`, `WRITE`, `EXEC`, `MAP`, `JIT`, `INSPECT`, `DESTROY`, without `CHILD`, `DUP` and `GIVE`, so it has one capability and no copy of it exists elsewhere |
| a paged object | `READ`, `MAP`, `SUPPLY`, `CHILD`, `INSPECT`, `DUP`, `GIVE`, `DESTROY`, plus `EXEC` with `ERX_MEM_CODE` |
| a copy-on-write child | `READ`, `WRITE`, `MAP`, `INSPECT`, `DUP`, `GIVE`, `DESTROY` |
| the boot image | `READ`, `EXEC`, `MAP`, `CHILD`, `CARVE`, `SYSTEM`, `INSPECT`, `DUP`, `GIVE`, never `WRITE` and never `DESTROY`: every right a slice is created with, `DESTROY` aside, which the carve adds, so a slice's rights, the intersection, are the next row's; its empty ceiling keeps `MAP` and `EXEC` from ever mapping it, and it parents no child ([Copy-on-write children and copies of spaces](#copy-on-write-children-and-copies-of-spaces)) |
| a slice of the boot image | `READ`, `EXEC`, `MAP`, `CHILD`, `INSPECT`, `DUP`, `GIVE`, `DESTROY` |
| the time page | `READ`, `WRITE`, `MAP`, `INSPECT`, `DUP`, `GIVE`; its read-only ceiling keeps `WRITE` from ever mapping it writable, and `WRITE` only lets `erx_time_set_wall` update it |
| the machine page | `READ`, `MAP`, `INSPECT`, `DUP`, `GIVE`, with a read-only ceiling; the kernel alone writes it, and the system domain gives read-only views of it |
| the previous crash record | as the machine page, plus `DESTROY`, so the system domain can free its pages once the inspector has shown it |
| the device-secret page | `READ`, `MAP`, `INSPECT`, without `WRITE`, `CHILD`, `DUP`, `GIVE` and `DESTROY`, so it has one capability, the root task's, which no copy, pass or fork can reach, since rights only shrink (K2) |

Rights are an opaque value with two constructors, so that growing a right
is not expressible:

```c
typedef struct erx_rights {
	uint32_t	bits;		/* ERX_HR_*; built only by the two below */
} erx_rights_t;

erx_rights_t	erx_rights_create(erx_create_kind_t kind);
erx_rights_t	erx_rights_shrink(erx_rights_t rights, uint32_t mask);
```

`erx_create_kind_t` is a closed enumeration with one value for each row
of the two tables above: a type whose rights do not depend on how it is
made has one kind; a budget has two, the root budget, which the boot
step creates without `DESTROY`, and a carved budget; a memory object has
one kind per row of the memory table; an IRQ object one per kind of
`erx_irq_create`; a resource one for the root resource and one for a
carved resource. The ABI file declares
the default rights per kind, and the generator emits `erx_rights_create`
as a lookup over that table and checks it against the types' carryable
sets. A creation's validated plan produces the kind from the call's
arguments, and the install takes the kind, so no creation can be given
the union of two kinds' rights, and a carve is a shrink of a create:
`erx_rights_shrink(erx_rights_create(kind), through.bits |
ERX_HR_DESTROY)`.

A table receives capabilities in four ways only (K17): a creation call
installs the default rights of what it made into the caller's own table;
`erx_cap_dup` installs a copy of a capability into its holder's own table
([Closing and deleting](#closing-and-deleting)); a **pass** installs
capabilities into slots the receiver reserved, at a rendezvous or by
`erx_cap_pass` ([Passing capabilities](#passing-capabilities)); and
`erx_space_copy` fills a forked child's fresh table with copies of what
carries `DUP`, within each type's pass set ([Copy-on-write children and
copies of spaces](#copy-on-write-children-and-copies-of-spaces)).
`erx_cap_pass` needs `CAPS` on both of its spaces, and `CAPS` on a space
other than the caller's own is held only by that space's creator: the
creating call puts the space's capability, with every right, into the
creator's table, and a pass hands a space's capability on with `INSPECT`
alone, so `MAP`, `THREADS`, `CAPS` and `STOP` on a space never leave its
creator's table (K17). The creator's pass into such a space is the one
pass the pass sets do not bind, which is how code, devices and structure
reach a space: the system domain passes domains their initial
capabilities and their devices
([design-system.md](design-system.md#creating-a-domain)), and a domain
passes its sub-spaces what they hold, as a session does for its programs
([Creating spaces](#creating-spaces)). A
call that carves an object from another (a budget from a budget, a
resource from a resource, a slice from the boot image) installs the
child's default rights intersected with the rights of the parent's
capability and `DESTROY`, so a carved object never carries a right its
parent's capability lacked, except the right to delete the carving
itself, which reaches nothing the carver did not make. Each
root of a carve holds every right its carving is created with but
`DESTROY`, which the generator's check of the type and memory tables
proves: the root budget's capability holds a carved budget's rights, the
root resource's a carved resource's, and the boot image's a slice's,
never `WRITE`. A carve through a narrower capability makes a narrower
carving, as intended.

`SPACES` on the budget that pays authorises creating a space. It is an
ordinary right: a carved budget carries it only if its parent's capability
did, and a giver masks it out like any other. `CODE` on the budget that
pays authorises creating a paged object whose pages may be executed, and a
JIT space from a space that is not one. It never leaves the system
domain's table: the root budget's capability carries it, a budget carved
through a capability that carries it carries it in the carver's own
table, budgets never pass between peers, and no pass conveys it, the
creator's included. So only the system domain creates objects whose pages
a program may execute (K8),
and each is charged to the budget of the domain it is for, through the
system domain's own capability to that budget.

Authority flows outwards from the system domain, the root task: a domain
holds what the system domain gave it and what it created, each narrowed
on the way ([design-system.md](design-system.md#authority)), and a
sub-space what its creator gave it. Spaces that share a gate pass
capabilities at a rendezvous within the pass sets, which is the ordinary
way within a domain's tree of spaces, between a session and its programs
or a domain and its sub-spaces. No capability passes between two
domains: the domain library, the one installer into a domain's table,
installs connections and resources, maps the sealing page into the
vault's domain, and never installs a gate of another domain, and no
system manifest introduces a gate that two domains share. Memory
therefore crosses a domain boundary only in objects the system domain
created and charged to an outer budget or a child of one
([Budgets](#budgets)).

### Budgets

A **budget** is the kernel's unit of accounting for memory, and a space
bank in EROS's sense: a **guarantee** carved from its parent, a **cap**
on what it and the budgets below it may spend, counters of what is
charged to it, and the list of the objects charged to it, every one of
which dies with it. The guarantee is memory set aside for the budget
alone, which no other budget can take; the cap is how far the budget may
spend beyond its guarantee, into memory its ancestors have not promised
to anyone. A budget is carved as one of two **kinds**, fixed for its
life. A **wall** has a cap equal to its guarantee at every moment, so a
charge below it is admitted or refused at the wall and never by an
ancestor's room. An **elastic** budget's cap may exceed its guarantee.
The root budget, each
principal's budget, each domain's budgets and a session's pool for its
programs are walls, so a domain's memory depends on nothing outside it
but the kernel ([design-system.md](design-system.md#resource-policy)); a
program's budget is elastic, with the pool as its cap, so a program
spends what its siblings are not using, as a QNX process draws on the
system's pool within its `RLIMIT_AS`
([design-programs.md](design-programs.md#a-program-is-a-port)).

```c
typedef struct erx_budget {
	erx_object_t	 obj;		/* obj.budget is its parent; NULL for the root */
	erx_spinlock_t	 lock;		/* the counters, dead, the watch and caches */
	erx_budget_kind_t kind;		/* ERX_BUDGET_WALL or ERX_BUDGET_ELASTIC;
					 * fixed at carving */
	uint64_t	 guarantee;	/* pages carved from the parent: its floor */
	uint64_t	 cap;		/* pages its tree may spend: its ceiling;
					 * never below guarantee, equal to it for
					 * a wall */
	uint64_t	 used;		/* pages charged here and not yet released:
					 * the reserves of the objects charged
					 * here, its own cache pages among them;
					 * at a dead budget, what still names it */
	uint64_t	 pinned;	/* pages its tree holds that will never be
					 * released: those a failed IOMMU keeps,
					 * and the cache pages of records kept for
					 * the boot; counted at every ancestor */
	uint64_t	 carved;	/* its children's guarantees */
	uint64_t	 lent;		/* what its children spend beyond their
					 * guarantees */
	bool		 dead;		/* closed by its destroy; takes no charge,
					 * and its spending is counted in its
					 * nearest live ancestor's used */
	uint64_t	 threshold;	/* spending at which the watch fires; 0 unarmed */
	erx_irq_t	*watch;		/* the IRQ object the watch triggers, whose
					 * att_watched names this budget; NULL
					 * for none */
	uint32_t	 depth;		/* 0 for the root; below ERX_BUDGET_DEPTH_MAX */
	erx_kcache_t	 caches;	/* its cache pages of kernel records, by
					 * record kind; under lock */
	erx_dlist_t	 att_charged;	/* every object charged here, child
					 * budgets included; under lock */
} erx_budget_t;
```

A budget's **spending** is `used + carved + lent`: what is charged to it,
what it guarantees to its children, and what its children spend beyond
their guarantees. What spending exceeds the guarantee by, if anything, is
what the budget **borrows**, and its parent holds exactly that in `lent`;
so `lent` is the sum of the children's borrowing, a budget's **room** is
`cap - spending` while that is positive and zero otherwise, and the part
of its guarantee it has not spent is `guarantee - spending` while that is
positive. The root's guarantee and cap are both every page the root
budget holds, so the root borrows from no one. A child budget is an
object charged to its parent like any other, so the budgets form a tree
in which each budget's `att_charged` reaches everything below it.
`ERX_BUDGET_DEPTH_MAX` (16) is the number of levels the tree may have,
the root at depth 0 and the deepest budget at depth 15, so a chain from
any budget to the root holds at most `ERX_BUDGET_DEPTH_MAX` budgets.

* **One function changes the counters.** Every charge, refund, carve,
  resize and destroy goes through `erx_budget_adjust(budget, dused,
  dcarved, dlent)`, which plans the change along the budget's chain of
  ancestors and applies it whole or not at all. At a live budget it
  computes the new spending and the change in borrowing: the new
  spending less the guarantee, if positive, less the old borrowing. A
  change in borrowing is a change of `lent` at the parent, planned there
  by the same rule, and so on up the tree until a budget's borrowing does
  not change or the root is reached: a charge within the guarantee
  touches one budget, as every admitted charge of a wall's does, since a
  wall has no room to borrow. At a dead budget (**Destroying** below)
  the whole change in spending is instead a change of `used` at the
  parent, since the parent counts a dead budget's spending in its own
  `used`; the parent, live or dead, plans it by its own rule. The plan
  refuses with `ERX_ENOMEM` when the new spending at any live level
  exceeds that level's cap, naming the level that refused, and nothing
  changes; a decrease never fails. The locks are taken descendant first,
  their place in the kernel's order ([Execution model and
  locking](#execution-model-and-locking)), and held together until the
  plan is applied, so no other call ever sees a budget's spending above
  its guarantee before its parent's `lent` holds the difference; the
  chain holds at most `ERX_BUDGET_DEPTH_MAX` spinlocks and has no
  preemption point inside it. Two invariants follow for every budget,
  checked by the host model of the accounting (K32): no charge takes a
  live budget's spending above its cap, and `lent` equals the sum of its
  live children's borrowing, so every byte any live budget spends is
  counted, through the chain, against the guarantee of exactly one
  ancestor whose guarantee covers it, or the root's.
* **Guarantees are backed and never shared.** A child's guarantee is
  `carved` at its parent, and `carved` is part of the parent's spending,
  so lending never eats into it: a sibling that borrows takes only the
  parent's room, never what the parent guarantees to another child. A
  parent may itself borrow to back a child's guarantee, as for any other
  charge, so by induction every guarantee is covered, at the root, by
  pages that exist. A wall takes no new charge beyond its guarantee: a
  charge's chain ends at the first wall, admitted within its guarantee or
  refused there, so nothing below a wall is ever admitted or refused by
  an ancestor's room. A wall borrows only when its carver shrinks it
  beneath its spending (**Resizing** below): the excess is then
  borrowing, which the parent counts in `lent` as the carver's own
  resize put it there, and which falls as the wall's tree releases
  memory, since every charge that would raise the wall's spending is
  refused meanwhile.
  That is why a domain's own and outer budgets, both walls, wall every
  domain's memory off from every other's: a domain is admitted or
  refused at its own budget alone, what it holds was counted when it was
  charged, and what counts against its principal's room beyond its
  guarantee is only what the principal's own policy moved there by a
  shrink.
* **Carving.** `erx_budget_create(parent (CARVE), kind, guarantee, cap)`
  refuses with `ERX_EINVAL` a cap below the guarantee, or for a wall a
  cap other than the guarantee, and with `ERX_ELIMIT` a parent at depth
  `ERX_BUDGET_DEPTH_MAX - 1`; it charges the child's record and its
  guarantee to the parent, as `used` and `carved`, through
  `erx_budget_adjust`, which may borrow for them, and installs the child
  with the default rights
  intersected with the rights of the capability carved through and
  `DESTROY` ([Rights](#rights)).
* **Resizing.** `erx_budget_resize(budget (DESTROY), guarantee, cap)`
  sets both in one step, under the budget's lock and its chain; for a
  wall, a cap other than the guarantee fails with `ERX_EINVAL`, and for
  any budget a cap below the guarantee does. Resizing is the carver's
  authority: `DESTROY` on a budget enters a slot only when the budget is
  carved, into the carver's table (K2), and reaches another space only by
  the carver's own pass into a space it created with a mask that keeps
  it, which is how any right is delegated ([Passing
  capabilities](#passing-capabilities)); the root budget, which nothing
  holds with `DESTROY`, is resized by no one, and the domain library
  passes no budget with `DESTROY` to a domain, so a domain never resizes
  its own budgets ([design-system.md](design-system.md#the-domain-library)).
  Growing the guarantee charges the growth to the parent's `carved` and
  takes back from its `lent` whatever the budget borrowed that the larger
  guarantee covers, one adjustment of the parent, which fails with
  `ERX_ENOMEM` when the chain cannot cover the growth, and then nothing
  changes; shrinking the guarantee, even below the spending, never fails:
  the part of the spending the smaller guarantee no longer covers becomes
  borrowing, the parent's `carved` falls by the whole shrink and its
  `lent` rises by at most that, so the parent regains at once what the
  budget was not using and regains the rest as the budget's tree
  releases memory. A cap
  may be set below the spending, as `setrlimit` sets a limit below the
  current use: every charge that would raise the budget's spending then
  fails until the spending falls beneath the cap. A shrink revokes
  nothing the budget has carved for its children: a child's charge
  within the child's own guarantee raises only the child's spending,
  since the parent already counts that guarantee whole in `carved`, so
  it is admitted whatever the parent's cap, and a child's guarantee is
  taken back only by shrinking the child. A charge and a resize of the
  same budget serialise on its lock, so the plan of each sees the whole
  of the other.
* **Watching.** `erx_budget_watch(budget (ALLOC), irq (TRIGGER) or
  `ERX_CAP_NULL`, threshold)` arms one notice: the first adjustment that
  takes the budget's spending from below `threshold` to at or above it
  triggers the IRQ object once and disarms the watch. Arming while the
  spending is already at or above the threshold triggers at once and
  leaves the watch disarmed, so a holder that read the spending, chose a
  threshold and lost a race with a charge in between is told rather than
  left waiting; after each notice the holder re-arms, with a higher
  threshold or after trimming. The notice is advisory: it says the
  spending crossed the threshold, not that the next charge will fit, and
  a charge larger than the room can be refused without any threshold
  having been crossed. A budget has at most one watch and an IRQ object
  is the watch of at most one budget: the budget's `watch` and the IRQ
  object's `att_watched`, an attachment field holding the one budget
  that names it, are written together under the IRQ object's capability
  lock and then the budget's lock, in the kernel's order, by the arm, by
  the disarm with `ERX_CAP_NULL`, and by either object's teardown, and
  no writer of the pair holds any other capability lock meanwhile: the
  IRQ object's teardown holds its own, as every teardown does, and takes
  the budget's lock inside it; the budget's teardown detaches its watch
  in a bounded part of its own that holds no capability lock, which
  reads `watch` under the budget's lock, takes a counted reference to
  the IRQ object it names, takes that object's capability lock with
  `erx_object_lock` and then the budget's lock, and clears both ends
  only if `watch` still names the object, since the object's own
  teardown may have cleared the pair meanwhile. So the address order in
  which a pass holds several capability locks is never reversed against
  a teardown ([Execution model and
  locking](#execution-model-and-locking)); arming names a
  different IRQ object while one is armed, or an IRQ object that is
  another budget's watch, fails with `ERX_EBUSY`, so a holder disarms
  before it changes the object, and arming the same object again sets a
  new threshold. The crossing is decided under the budget's lock; the
  trigger is an effect the adjustment or the arm returns and its caller
  performs after releasing every lock and before its next preemption
  point, since an IRQ object's lock is a leaf and a deleted object's
  record outlives the call's current part, and a trigger on a closed IRQ
  object does nothing. A runtime watches its own budget to trim before it
  is refused; a session or the policy watches the budgets it carved to
  resize them, or the pool its programs draw on, before a program is
  refused, with one software IRQ object per watched budget.
* **Inspecting.** `erx_object_info` on a budget reports, in its basic
  topic, `kind`, `guarantee`, `cap`, `used`, `carved`, `lent`, `pinned`
  and `threshold`, from which the inspector derives the spending, the
  room, which is zero when the spending is at or above the cap, the
  **deficit**, the spending above the cap after a shrink, the
  borrowing, and what a destroy of the budget would give back to its
  parent, the guarantee plus the borrowing less `pinned`, which never
  wraps, since `pinned` counts pages the tree holds and the tree holds no
  more than the guarantee and the borrowing cover, and which is exact,
  since a pin counts at once the cache pages of every record it keeps
  for the boot, so a destroy moves nothing into `pinned` (**Pinning**
  in [DMA and the IOMMU](#dma-and-the-iommu)); `abi/inspection.txt`
  declares them under `budget`, and the inspector shows a budget's
  borrowing beside its guarantee so that a program's draw on its
  session's pool is visible as such ([design-live.md](design-live.md)).
  A dead budget is inspected by nobody: its capabilities fail the lookup
  from its close on, and what it still holds is in its nearest live
  ancestor's `used` and `pinned`, where the inspector reads it.
* **Charging.** Every page the kernel holds is held by a **reserve**,
  and every reserve by a budget. A reserve is the record of the pages
  one owner was promised, and it is **backed** when it is charged, so no
  promise is ever made that a page cannot keep (K6):

  ```c
  typedef struct erx_reserve {
          erx_npages_t     charged;  /* pages admitted to the owner: what its
                                      * budget's used counts for it */
          erx_npages_t     backed;   /* pages the reserve holds, in use or in
                                      * its pool; equal to charged except
                                      * while a backing of this reserve is
                                      * in progress */
          erx_plist_t      pool;     /* backed pages not yet in use, chained
                                      * through their page records */
  } erx_reserve_t;
  ```

  A space's reserve holds its translation tables, its capability table
  and its private memory; a shared, paged or copy-on-write object's
  holds the object's pages; a thread's its kernel stack and kernel-user
  page; a group's its per-CPU records and shared areas; and each budget
  has a reserve of its own for the cache pages its kernel records are
  carved from, under the budget's lock, so a cache page is charged whole
  to its budget while it holds any record, a budget pays for its own
  fragmentation, no cache is shared between budgets, and the page is
  released when its last record is freed. The charge is made at the
  moment the memory is promised, by the call that commits, creates or
  grows, never at a fault: `erx_reserve_charge(reserve, n)` admits `n`
  pages through `erx_budget_adjust`, borrowing through the chain then or
  refusing with `ERX_ENOMEM` and changing nothing, and then backs them,
  taking `n` pages from the page allocator into the reserve's pool in
  bounded parts, and taking released pages off the released list when
  none is free ([The reaper](#the-reaper)). The call that backs a
  reserve holds the owner's existence lock from the admission to the
  last part, so the owner's destroy, which drains that lock, never runs
  its teardown while a backing is under way, the one exception being a
  budget's cache page, a backing of one page that the reaper section
  settles under the budget's lock; a backing that finds the
  owner closed between its parts admits nothing more, puts what it has
  taken into the pool once mature and gives the rest of the admission
  back through `erx_reserve_cancel(reserve, k)`, which lowers `charged`
  and refunds `k` promises through `erx_budget_adjust`, a decrease that
  never fails; so an admission is cancelled exactly once, by the backing
  that made it, and every page a reserve holds is released exactly once,
  by the owner's teardown ([The reaper](#the-reaper)). A page comes into
  use only from its reserve's pool, through `erx_reserve_take(reserve)`,
  under the owner's lock, which zeroes it and never fails: between calls
  a reserve's pool holds a page for every promise not in use, since every
  use consumed a promise and every promise was backed. Admission and
  population are thus two operations that cannot be confused: the charge
  has no page to put in use and the take has no budget to charge, so a
  page is never charged twice and never taken beyond a promise, and a
  fault, which only takes, never allocates and never waits
  ([Virtual memory](#virtual-memory)).
* **Who pays.** Every creation call names its budget, with the `ALLOC`
  right, and what it makes is on that budget's `att_charged` from its
  first charge, as a construction record and then as the object that
  replaces it there when it is published, each through the list's one
  insert function, which refuses a dead budget with `ERX_ESTALE`
  (**Construction**, [The reaper](#the-reaper)): a space's budget pays
  for its records, translation tables,
  private memory and capability table, whoever makes the call later; a
  memory object's budget pays for its pages; a group's for its per-CPU
  records and shared areas; a thread's for its record, its kernel stack
  and its kernel-user page. No call site chooses a budget by itself, and
  none can forget one.
* **Freeing never shows.** A charge ends when the memory is released,
  not when it is freed. The one function that releases pages,
  `erx_page_release(reserve, pages)`, appends them to the released list
  and then, in the same bounded part, takes them out of the reserve's
  `backed` and `charged` and refunds their charge through
  `erx_budget_adjust` ([The reaper](#the-reaper)); a released page
  lowers its budget's `used`, and through the chain the `lent` of every
  ancestor it was borrowed through, so the room comes back where a
  charge needs it. The pages one program of a session released are
  therefore out of that program's `used`, and out of the pool's `lent`
  if it borrowed them, before the call that released them reaches its
  next preemption point, and a sibling that commits the same amount
  meanwhile is admitted. No admission waits for a grace period, for a
  reaper step or for another budget's work, and no refusal depends on
  when the reaper runs or on what is carved or destroyed meanwhile: a
  refusal says that the tree's charges reach the cap, nothing else. The
  physical pages are then where the backing of an admitted charge finds
  them: every charge is covered by the root's pages (K32) and every page
  is held by a reserve, in a backing's hand, on the released list or
  free, so a page an admitted charge has yet to take is free, or on the
  list and fewer than two grace periods from free, and the backing takes
  it off the list itself and waits that time out, on no party; it never
  fails, and it never loses a page it took ([The reaper](#the-reaper)).
  So admission never waits: `erx_budget_adjust` admits or refuses at
  once, from the counters alone. What may wait is the backing inside
  `erx_reserve_charge`, for the grace period of pages it took off the
  released list, which happens only while the machine has no free page,
  costs the caller that backs the charge and nobody else, and is bounded
  in [Security](#security); otherwise freeing takes only idle time.

  What a budget cannot reuse at once after a destroy is its kernel
  records' cache pages alone. A record is memory a call in progress may
  still read, so its slot returns to its budget's cache only after its
  object's grace period and its last counted reference, and a cache page
  is released only when it holds no record. A budget that destroys
  records and at once needs new ones therefore takes new cache pages
  while the old records wait, at most the pages whose every record its
  tree destroyed, never a page of a memory object or a space, and the
  wait has four parts, each with its bound: the object's put runs after
  its grace period, which begins at the first period boundary after the
  destroy and so ends within two grace periods, plus the reap deadlines
  of the CPU that queued it, one for each 64 items queued there ahead of
  it and one more, and one part ([The reaper](#the-reaper)); a counted
  reference that a call of another thread holds across a preemption
  point, as a memory window's caller holds its source between the parts
  of `erx_mem_copy`, drops at that call's next part, on its own group's
  time, which is any time at all if that group is not scheduled; and a
  dead budget's own record, the tombstone below, waits one further
  round, a grace period and its deadlines, for each dead budget beneath
  it, fewer than `ERX_BUDGET_DEPTH_MAX`; and a destroyed space's record
  waits for every child's record, each deleted by the same walk and
  waiting only for its own grace period, its finishing threads and the
  calls under way on it, and then one round, for each level of a chain
  of deleted spaces, at most `ERX_SPACE_DEPTH_MAX`. So when no call holds
  the destroyed records or a record below them, a charge refused for cache pages is
  refused for a grace period, the reap deadlines its records' backlog
  needs and a part, with one round more for each level of a chain of dead
  budgets and released spaces above the page's last record, and otherwise
  until the holders let go, which [Security](#security) bounds.
* **Destroying a budget deletes everything charged to it.** A budget is
  destroyed by `erx_object_destroy` with `DESTROY`, by the destruction of
  its parent, or by its release when its last capability goes, as every
  type but memory and groups is. The destroy first **closes** the budget,
  under its lock and its chain: it marks the budget dead, one store,
  and in the same adjustment moves what the budget spends to its parent,
  whose `carved` loses the budget's guarantee, whose `lent` loses what
  the budget borrowed, and whose `used` gains the budget's whole
  spending; `pinned` moves nowhere, since every ancestor counts it
  already (**Pinning**, [DMA and the IOMMU](#dma-and-the-iommu)). The
  spending never exceeds the guarantee plus the borrowing, so the
  parent's spending never rises at a close, the adjustment never fails,
  and the parent regains at once the guarantee the budget was not using. From the store on, `erx_cap_lookup` refuses
  every object charged to the budget, since the lookup checks the
  object's budget as well as the object, and the insert function of
  `att_charged` refuses every new charge; so no call reaches any object
  the budget pays for and none can be added. The destroy then walks
  `att_charged` in bounded parts and destroys each object on it as a
  deletion would ([Closing and deleting](#closing-and-deleting)), so
  every capability, mapping, binding and waiter of each goes as K26
  says. A construction record on the list, an object its creator is
  still making, is closed and drained the same way, and the drain helps
  the creator to the end of its construction: its backing admits
  nothing more once it finds the construction closed, its publication
  is refused by the dead budget, and the creator tears down what it
  made and refunds it at the dead budget before it releases the
  construction's lock, so the drain returns with nothing of the
  construction left charged (**Construction**, [The
  reaper](#the-reaper)). A child budget on the list is closed when the walk reaches it,
  by the same close, whose parent is then dead, and its own list is
  walked next, by the same iterative walk, so the objects charged below
  the budget are unreachable from their own budget's close on, and all
  of them before the call that destroyed the budget returns. Until the
  walk reaches it, a budget below a dead one is **doomed**: its own
  `dead` is clear, and a space charged to it is still reachable, so it
  still takes charges, but every one of them is counted at the nearest
  live ancestor already, since the close moved the doomed budget's
  guarantee whole and its borrowing into that ancestor's `used`, and
  what it borrows anew passes through its dead parent as a change of
  `used` there. The accounting rule for a tree midway through a destroy
  is therefore that a budget's counters count toward the machine only
  while it is live itself and every budget above it is live: what is
  charged to the machine is the sum of `used` over those budgets, before
  and after each close of the walk, and a dead or doomed budget's
  counters are excluded from that sum, since the live ancestor's `used`
  already holds what they cover. What a doomed budget releases within
  its guarantee shows at the live ancestor only when the walk closes it,
  since until then the ancestor counts its guarantee whole; what it
  releases beyond its guarantee, and everything the tree releases after
  its close, leaves the ancestor's `used` through the same chain as any
  refund. The walk closes every budget of the tree before the destroy
  returns, so by then the parent has regained, from its own counters,
  everything the tree held but the records below and the pages a failed
  IOMMU pinned ([DMA and the IOMMU](#dma-and-the-iommu)).
* **A dead budget's record stays as a tombstone until its memory has
  returned; its counters are excluded from the aggregate, and the cache
  page its record sits in stays charged to its parent.** The walk
  releases the pages of every object it destroys, so the dead tree's
  data pages leave the ancestor's `used` before the destroy returns, or
  for a space another call's walk unlinked, before that call returns;
  what outlives the walk is records, and pinned pages.
  Objects never hold counted references to each other, only
  attachments, which each teardown removes ([Objects and
  capabilities](#objects-and-capabilities)), but every record waits out
  its grace period, and a thread of another budget may hold an object
  counted across a preemption point, as a memory window's caller does
  between the parts of `erx_mem_copy`, and drops it only when its call
  next runs, on its own group's time. Every object names its budget for
  good, so the budget's record outlives the walk, and every refund of
  what was charged to a dead budget, the cache pages its records sit in
  among them, goes through `erx_budget_adjust` at the dead budget as at
  a live one: its counters fall, and the fall passes to its parent's
  `used`, and on through any dead parent to the nearest live ancestor,
  which is the one budget that counts the memory. So what a dead budget
  still holds is counted exactly once, in the `used` of its nearest live
  ancestor, from the close until it is released; the dead budget's own
  `used` is the count of what still names it and no charge, a count
  nobody inspects, since the dead budget's capabilities fail the lookup
  (**Inspecting** above). The refund that leaves a dead budget with
  `used` zero, or the close itself when nothing was charged to it,
  queues the put of the budget's own record behind a grace period, and
  the record is freed last, from its parent's cache, whose page stays
  charged to the parent until it holds no record; it comes no earlier
  than the release of the cache page holding the last of the budget's
  records, and so not before the last counted reference to any object
  charged to it has dropped. A parent destroyed meanwhile keeps its own
  tombstone at least as long, since the child's record names it, and is
  freed one round after the child's record, a grace period and the reap
  deadlines its CPU's backlog needs: a chain of dead budgets goes one
  level per round, and a chain is at most `ERX_BUDGET_DEPTH_MAX` long.
  So a tombstone waits only for grace periods, for reap deadlines,
  for calls already under way to reach their next part, on their
  callers' time, and, for a space's record charged to it, for the records
  below that space, which its deletion deleted with it and which wait for
  the same things alone; and meanwhile the nearest live
  ancestor counts what the budget had charged when it was destroyed, never
  its unspent guarantee;
  nothing of a destroyed budget is ever handed back to anyone. A budget
  whose `pinned` is not zero when it closes keeps its tombstone for the
  rest of the boot, since its `used` never reaches zero, and the cache
  page that holds the tombstone was pinned, at its parent and every
  ancestor, when the pin that first raised the budget's `pinned` was
  made, as every page that holds a record kept for the boot is; the
  close pins nothing (**Pinning**, [DMA and the
  IOMMU](#dma-and-the-iommu)).
* **Charging without deleting.** Charging a budget needs `ALLOC` on it;
  destroying it needs `DESTROY`, which a carved budget's capability
  carries in the carver's table and which a pass drops whenever the
  carver's mask leaves it out. So a space can hold a budget it may charge
  and cannot destroy or resize: a capability with `ALLOC` and without
  `DESTROY`, which is every budget a domain holds. The space-bank rule
  follows from the tree: destroying a budget deletes every object charged
  to it and every budget carved from it, since a carved budget is itself
  an object charged to its parent.
* **What must outlive a domain is charged to a budget that outlives it.**
  Ending a domain is destroying its budget, after which every capability
  to its objects fails the one lookup and every mapping of them faults
  (K25, K26), so each party charges what it creates to the budget whose
  life it should share. The domain library carves two budgets for each
  domain, side by side from the same parent
  ([design-system.md](design-system.md#the-domain-library)), the domain's
  **own** budget and its **outer** budget:
  * *Rights.* The domain holds its own budget with `ALLOC` and without
    `DESTROY`, and receives no capability to its outer budget or to any
    child budget carved from it: only the system domain charges the outer
    budget, carves child budgets from it and destroys them.
  * *What each pays for.* The own budget pays for what the domain alone
    maps, among it what the system domain creates for the domain alone,
    its groups, fault gate and boot information, so they die with it,
    which is the intent. The outer budget pays for what another party
    maps or reads after the domain is gone, each connection through a
    child budget carved from the outer budget, one child per connection:
    each connection's side that the domain reads, with its doorbell, and
    the domain's connection to the system domain, whose one child holds
    both its lanes and both its doorbells. Only the domain's crash area,
    which the system domain alone reads, is charged to the outer budget
    directly. Nothing else crosses a domain boundary: the domain library
    has no entry that maps one domain's memory into another but
    `erx_dom_connect`, which makes a connection, so connections and the crash area are all an
    outer budget ever holds. The domain holds no capability to its
    outer budget or to any child of it.
  * *When each goes.* The system domain destroys the own budget at once
    when the domain ends; it destroys each connection's child budget once
    both parties have let go of it, in `erx_dom_disconnect`; and
    `erx_dom_retire` destroys the outer budget only
    once no child budget remains and the crash area has been read
    ([design-system.md](design-system.md#the-domain-library),
    [design-domains.md](design-domains.md#connections)). So the death of
    a domain deletes nothing another domain maps, a survivor that never
    lets go keeps alive its connection's child budget, and the outer
    budget it was carved from, but no other connection's lanes, and the
    rule for servers holds ([Closing and
    deleting](#closing-and-deleting)).

  The same rule places what other parties create: a session charges its
  programs to its own budget, so they die with the session, and a file
  server charges the objects it serves to its own, so they live as long
  as the server.

At boot the kernel creates the **root budget** from every page left after
its own carve-outs (the kernel image, its tables, the device tree, the boot
image, the per-CPU areas, the idle threads, the crash buffer and the
contiguous pool for unconfined devices' DMA memory, which exist before the
root does): those pages are its guarantee and its cap, and the page
allocator's whole universe ([The reaper](#the-reaper)).
The root task holds it, with `SPACES` and
`CODE` and without `DESTROY`, so no call deletes or resizes it; since everything is
charged below it, its release, if the root task closed its last
capability to it, would destroy the root task too, which ends the machine
as the root task's halt does (K31).

### Memory

A **space** is the translation and the authority of one domain or
sub-space: a root translation table, an ASID (the tag that lets the TLB
hold several spaces' translations at once), a tree of mapping records, a
capability table, and its place among spaces.

```c
/* An intrusive doubly linked list: a head, and a link in each element. */
typedef struct erx_dlink {
	struct erx_dlink  *next, *prev;
} erx_dlink_t;

typedef struct erx_dlist {
	erx_dlink_t	   head;
} erx_dlist_t;

typedef struct erx_space {
	erx_object_t	   obj;
	erx_hlock_t	   lock;	/* records, tables, the reserve */
	erx_pte_t	  *root_table;	/* root translation table */
	erx_asid_t	   asid;	/* value and generation */
	erx_map_tree_t	   att_maps;	/* its mapping records by address, each
					 * also on its object's reverse map */
	erx_cap_table_t	  *caps;	/* used by the threads of this space; its
					 * record, of erx_cap_table_size() bytes,
					 * is charged to the space's reserve */
	struct erx_space  *parent;	/* fixed at creation; NULL for the first;
					 * valid for this record's whole life,
					 * since a record is freed only after
					 * every child's; never counted */
	erx_dlist_t	   children;	/* its children whose deletion has not
					 * begun, those not yet walked first: a
					 * child moves to the end when a stop walk
					 * marks it walked and leaves when its
					 * deletion begins; under lock */
	erx_dlink_t	   in_parent;	/* on its parent's children list until
					 * its deletion begins; under the
					 * parent's lock */
	uint32_t	   unposted;	/* children whose exit records are not
					 * yet posted; under lock */
	_Atomic uint64_t   holds;	/* what keeps this record: each child's
					 * record not yet freed, and its own until
					 * it is ready to free; the drop to zero
					 * frees it; a count of records, not a
					 * reference ([Creating
					 * spaces](#creating-spaces)) */
	uint32_t	   depth;	/* 0 for the first; at most ERX_SPACE_DEPTH_MAX */
	erx_sign_keys_t	   sign_keys;	/* its pointer-signing keys, if the CPU has them */
	erx_reserve_t	   reserve;	/* its tables, capability table and private
					 * memory: charged, backed and pooled
					 * pages ([Budgets](#budgets)) */
	erx_uvpn_t	   map_base;	/* placement base; random per space */
	erx_gate_t	  *fault_gate;	/* receives its faults and its exit; on
					 * the gate's att_faulting; NULL once
					 * the gate is destroyed */
	erx_dlink_t	   in_fault_gate; /* its link on that list */
	uint64_t	   fault_label;	/* given to erx_space_create; on every record */
	uint32_t	   nmaps;	/* at most ERX_MAPPINGS_MAX */
	uint32_t	   nthreads;	/* at most ERX_THREADS_MAX */
	erx_dlist_t	   threads;	/* its threads not yet dead, those with no
					 * kill posted first: a thread moves to the
					 * end when its kill is posted; none joins
					 * once it has stopped or been closed;
					 * under lock */
	uint32_t	   flags;	/* ERX_SPACE_JIT */
	_Atomic uint32_t   stopped;	/* set once by its stop; read at every return
					 * to user mode and every preemption point */
	uint32_t	   walked;	/* set once, by the stop walk that finds
					 * every thread of it killed and every
					 * child walked; under the parent's lock */
	_Atomic uint64_t   holds;	/* one bit per slot, set while a hold
					 * occupies it: erx_space_pause sets the
					 * lowest clear bit, erx_space_resume
					 * clears the one its ticket names; both
					 * under lock */
	uint64_t	   pause_count;	/* pauses so far; the next ticket carries
					 * it; under lock */
	uint64_t	   hold_ticket[ERX_SPACE_HOLDS]; /* the ticket of the
					 * hold in each set slot; under lock */
	_Atomic uint32_t   quiesced;	/* set once active reaches zero under a
					 * hold; cleared by the resume that
					 * lifts the last hold */
	erx_spinlock_t	   copy_lock;	/* guards att_quiescers and att_stoppers */
	erx_tqueue_t	   att_quiescers; /* erx_space_quiesce waits for active to
					 * reach zero, each under one hold; all
					 * woken when it does, those under a hold
					 * when that hold is resumed */
	erx_tqueue_t	   att_stoppers; /* erx_space_stop waits for EXITED; all
					 * woken by the death that publishes it */
	_Atomic uint32_t   active;	/* threads running, or preempted inside a call */
	_Atomic uint32_t   exit_bits;	/* two bits, each set once: its exit record
					 * was posted, its deletion has begun */
	erx_thread_t	  *exit_at;	/* the thread whose queue has its record,
					 * NULL when on its gate's att_blocked;
					 * under the gate's lock */
	erx_fault_t	   exit;	/* the exit record: first stop's status and stopper */
} erx_space_t;

typedef enum erx_map_kind {
	ERX_MAP_RESERVED,	/* address space only; no access */
	ERX_MAP_PRIVATE,	/* committed private memory, read-write */
	ERX_MAP_OBJECT,		/* a memory object at an offset; keeps the object */
	ERX_MAP_DELETED,	/* an object mapping whose object was deleted: no
				 * translation; an access faults */
	ERX_MAP_KERNEL		/* a thread's kernel-user page; no range call changes it */
} erx_map_kind_t;

typedef struct erx_mapping {
	erx_uvpn_t	 start;		/* first page */
	erx_uvpn_t	 end;		/* exclusive */
	erx_memobj_t	*object;	/* PRIVATE: its private object; OBJECT:
					 * the record is on its reverse map;
					 * DELETED: NULL */
	erx_npages_t	 offset;	/* into the object */
	erx_map_kind_t	 kind;
	uint8_t		 prot;		/* ERX_PROT_NONE, _R, _RW or _RX; never W with X */
	uint8_t		 ceiling;	/* fixed when made; prot never exceeds it */
	uint8_t		 flags;		/* ERX_MAP_GUARDED: branch-target guarded pages */
} erx_mapping_t;
```

The user half's size comes from the architecture binding
([design-arch-aarch64.md](design-arch-aarch64.md#translation)); addresses
below 64 KiB are never mapped. Each record costs a kernel record charged to
the space's budget, and a space has at most `ERX_MAPPINGS_MAX` (65,536). The
tree supports split and join, so the records of any range come out as one
subtree in logarithmic time; two neighbouring records merge only if their
kinds, objects, offsets, protections, ceilings and flags line up; a call
that creates a record never merges it, and a deleted or kernel-user record
never merges; only the bounded range calls merge the record they rewrite
with a neighbour. A private record's offset is its first page, which no
call chooses, so the records of one private object name disjoint offsets
by construction.
The translation tables are a cache of the records and the objects' pages:
the kernel may drop any translation, and faults rebuild it from the
space's reserve; a table itself goes only with the promise that reserved
it, so a rebuild never needs a page the reserve does not hold, and range
calls stay bounded ([Virtual memory](#virtual-memory)).

A **memory object** owns or names physical pages:

```c
typedef enum erx_mem_kind {
	ERX_MEM_PRIVATE,	/* no capability; one mapping; freed by range */
	ERX_MEM_SHARED,		/* every page reserved at creation */
	ERX_MEM_CONTIGUOUS,	/* physically contiguous; unconfined DMA */
	ERX_MEM_PHYSICAL,	/* a fixed range: MMIO, a BAR, the boot image and
				 * its slices, the time page */
	ERX_MEM_PAGED,		/* filled by its supplier, then sealed;
				 * every page reserved at creation */
	ERX_MEM_CHILD		/* copy-on-write child of an immutable object;
				 * every page reserved at creation */
} erx_mem_kind_t;

typedef struct erx_memobj {
	erx_object_t	 obj;
	erx_spinlock_t	 lock;		/* the page tree and counters */
	erx_mem_kind_t	 kind;		/* selects the member of u */
	erx_npages_t	 npages;	/* its size */
	uint8_t		 ceiling;	/* most access any mapping may have */
	uint8_t		 attr;		/* normal, or one of the binding's device attributes */
	union {
		erx_mem_private_t priv;		/* page tree; a source range of the
						 * boot image, or none */
		erx_mem_shared_t  shared;	/* page tree; reserve; jit; sealed */
		erx_mem_fixed_t	  fixed;	/* base physical address */
		erx_mem_dma_t	  dma;		/* base; its device's DMA range */
		erx_mem_paged_t	  paged;	/* page tree; reserve; sealed */
		erx_mem_child_t	  child;	/* parent and offset, on the parent's
						 * att_children; own pages; reserve */
	} u;
	erx_rmap_t	 att_rmap;	/* its CPU and DMA mappings, for deletion */
	erx_dlist_t	 att_words;	/* umtx queues of its words, for deletion;
					 * under its object lock */
	erx_dlist_t	 att_children;	/* its copy-on-write children, deleted
					 * with it; under its object lock */
} erx_memobj_t;
```

The kind selects one member of `u`, and only accessors that check the kind
touch it, so no object can carry a page tree and a fixed base at once.

| Kind | Created by | Pages | Ceiling |
| --- | --- | --- | --- |
| private | `erx_vm_commit`; `erx_image_map` for a writable segment | populated at first touch from the space's reserve's pool: copied from the object's source (a range of the boot image) where it has one, zeroed elsewhere; released when the range that maps them is decommitted or released | read-write |
| shared | `erx_mem_create` | every page reserved, charged and backed at creation, and each page `erx_mem_grow` adds when it adds it, zero-filled at first touch from the object's own pool; released when the object is destroyed | read-write; with `ERX_MEM_JIT`, made by a thread of a JIT space, which becomes the object's owner, also execute, in its owner alone and never both in one mapping; read alone once sealed |
| contiguous | `erx_mem_create_contiguous` with the resource entry of the unconfined device it is for; at most 1 MiB, inside one DMA range of that device, below the limit its driver gives, from the contiguous pool | allocated and zeroed at creation; `PHYS` reveals the device's address for it | read-write |
| physical | `erx_mem_create_physical` from a resource, for MMIO and a PCIe function's BARs, and `erx_image_slice`, each charged to the budget it names; the boot image and the time page at boot; a group's shared areas | a fixed range, never freed while the object lives; a device range never overlaps RAM | MMIO: read-write, never execute, device attributes; the boot image: empty, so no mapping of it can be made; a slice: read and execute; the time page and a group's status area: read; a group's control area: read-write |
| paged | `erx_mem_create_paged`, by the system domain | every page reserved, charged and backed at creation; filled by its supplier from its pool until sealed, and never changed after; a page never supplied reads as zeros; released when the object is destroyed | read, and with `ERX_MEM_CODE` execute; mapped only once sealed |
| copy-on-write child | `erx_mem_child`, from an immutable object | every page reserved, charged and backed at creation; a page the child has not touched through a mapping is read from its parent through a memory window, and the first access through a mapping, a read or a write, copies it into a page of the child's pool, which the child owns from then on; released when the object is destroyed, which its parent's destruction does | read-write, never execute |

**Growing a shared object.** `erx_mem_grow(mem (SUPPLY), size)` extends a
shared object that is not sealed to `size`, rounded up to a page,
charging the added pages to the object's budget and backing them in the
call, in parts of at most 64 pages, or fails with `ERX_ENOMEM` and
changes nothing. It never shrinks an
object, so no mapping ever covers a page that goes away; a mapping covers
only what the object held when it was made, since `erx_vm_map` refuses a
range past the object's end with `ERX_ERANGE`. A session's mapper grows
the object that holds a mapped file as its programs map more of the file,
with the `SUPPLY` it keeps; a program's mapping of the object is made
through a capability with `READ`, `WRITE` and `MAP` alone
([design-files.md](design-files.md#shared-mappings)). Any other kind is
refused with `ERX_ETYPE`, and a sealed object with `ERX_ERIGHTS`.

**Trimming never meets sharing.** Only private memory is ever freed by
range, and private memory cannot be shared: no capability names a private
object, so no call can map it a second time, and its records partition its
offsets, so each of its pages is mapped at exactly one address of one space.
Decommitting or releasing a range therefore frees exactly the private pages
that the range maps. Every other kind, copy-on-write children included,
keeps its pages until the object is destroyed; on its mappings a range call
only drops translations, which faults rebuild. A source is a range of the
boot image's pages, which never change (K16) and are never freed, so
copying a page at first touch yields what copying it at creation would,
filling lazily needs no copy-on-write, and a source points at no object.

**Mappings keep their objects.** A mapping of an object is made through a
capability in the caller's table, into a space the caller holds with
`MAP`, with a ceiling fixed from that capability's rights (K4), and is on
the object's reverse map, not attached to the capability: closing or
moving the capability leaves the mapping, as closing a file leaves a Unix
process's mapping of it. A mapping goes when its space releases its range
or ends. When its object is deleted, the record stays, marked
`ERX_MAP_DELETED`, with no translation and no reference, until the space
releases its range, and every access to it faults with `ERX_FAULT_DELETED`
([Closing and deleting](#closing-and-deleting)). The object's reverse map
finds every mapping of it, for its deletion and for store tracking. None of
this needs a mapping database: a mapping is always made directly from an
object a capability names, never from another mapping.

### Threads

A **thread** is a set of user registers that the kernel runs in one space,
in one group, with a kernel stack of its own and a kernel-user page:

```c
typedef enum erx_thread_state {
	ERX_TS_STOPPED,		/* created, stopped by CONTROL, or faulted */
	ERX_TS_READY,		/* in its CPU's ready queues, or throttled */
	ERX_TS_RUNNING,		/* on its CPU */
	ERX_TS_WAITING,		/* asleep in a wait; see wait */
	ERX_TS_DEAD		/* its space stopped, or released */
} erx_thread_state_t;

typedef enum erx_wait_kind {
	ERX_WAIT_NONE,
	ERX_WAIT_SEND,		/* queued at a receiver, or at an unbound gate */
	ERX_WAIT_RECV,		/* an open wait, or a closed wait for one partner */
	ERX_WAIT_UMTX,		/* a umtx word */
	ERX_WAIT_PARK,		/* an executor in erx_park */
	ERX_WAIT_QUIESCE,	/* erx_space_quiesce, for the paused space's
				 * threads to finish their calls; the wait
				 * record names the hold it runs under */
	ERX_WAIT_STOP,		/* erx_space_stop, for the stopped tree's
				 * exit record */
	ERX_WAIT_PAUSED		/* at its return to user mode while its
				 * space is paused */
} erx_wait_kind_t;

typedef struct erx_thread {
	erx_object_t	 obj;
	erx_space_t	*space;		/* fixed; on its space's threads list */
	erx_dlink_t	 in_space;	/* on its space's list until it dies */
	erx_thread_state_t state;	/* changed only on its home CPU */
	erx_wait_t	 wait;		/* kind, partner or word, deadline, queue link */
	erx_kstack_t	 kstack;	/* its kernel stack, with a guard page below */
	erx_uregs_t	 uregs;		/* the user registers the binding lists */
	erx_fpstate_t	 fp;		/* the FP and SIMD state the binding lists */
	erx_kupage_t	*ku;		/* its kernel-user page: UTCB and vCPU area */
	erx_uvpn_t	 ku_at;		/* where ku is mapped in its space */
	erx_senders_t	 att_senders;	/* threads and IRQ objects waiting to deliver
					 * to it, by resolved urgency, then in order;
					 * its home CPU's (K14) */
	erx_dlist_t	 att_bound;	/* gates and IRQ objects bound to it,
					 * unbound when it dies */
	bool		 vcpu_armed;	/* by erx_vcpu_control; executors never */
	erx_slot_t	 room[ERX_MSG_CAPS]; /* slots reserved for a receive */
	struct erx_thread_sched sched;	/* class, group, urgency (design-scheduler.md) */
	erx_fault_t	 fault;		/* the last fault, while stopped by one */
	uint64_t	 cpu_ns;	/* CPU time run */
	char		 name[16];
} erx_thread_t;
```

The layout of `uregs` and `fp` is fixed per architecture, because the
exception entry stores into them at offsets from a generated header pinned
with `_Static_assert`. A thread's state, wait record and scheduling record
are changed only by its home CPU (K14); every other CPU posts a request.

**The kernel stack.** Every thread has a kernel stack of
`ERX_KSTACK_SIZE`, the stack proof's worst case for one synchronous path
with one interrupt on top, rounded up to whole pages: 8 KiB, an estimate
from Fiasco, whose thread blocks hold a thread's record and its kernel
stack in 8 KiB on 64-bit targets (`src/Kconfig`, `CONTEXT_8K`, and
`config_tcbsize.h`, snapshot 26.09). It lives in the kernel's stack region
with an unmapped guard page below it, and is charged to the thread's
budget with the record. Every kernel entry runs on the stack of the thread
that was running. An entry from user mode saves the user registers into
`uregs` first; an interrupt taken in kernel mode, at a preemption point,
saves the interrupted kernel registers as a frame on the stack and leaves
`uregs` alone, so `uregs` always holds the registers the thread last left
user mode with, and the stack holds only kernel frames.

**The kernel-user page.** Every thread has one page that the kernel owns
and maps into the thread's space, read-write and never executable, at an
address it picks when it creates the thread: the thread's **UTCB**, which
holds its message and buffer registers, and its **vCPU state area**
([Messages, gates and IRQ objects](#messages-gates-and-irq-objects)). A
thread-pointer register that user mode can read but not write holds the
page's address, as Fiasco keeps its UTCB's; the binding names it. The page
is charged with the thread, its mapping is of kind `ERX_MAP_KERNEL`, which
no range call changes, and it goes with the thread.

```text
  erx_thread_create        erx_thread_start          pick
  -----------------> STOPPED ------------> READY ------------> RUNNING
                        ^                    ^  ^  preempt, yield |  |
                        |                    |  `-----------------'  |
                        |  fault, CONTROL    |  wake, timeout        | wait
                        +--------------------+------- WAITING <------'
                        |
     its space stopped, release, destroy: every state -> DEAD
```

### Messages, gates and IRQ objects

**The kernel-user page.** Every thread's kernel-user page holds its UTCB,
Fiasco's user thread control block in Fiasco's layout, and its vCPU state
area:

```c
typedef struct erx_utcb {
	uint64_t	mr[ERX_MSG_WORDS];	/* 63 message registers: words, then items */
	uint64_t	self;			/* this UTCB's address in its space */
	uint64_t	bdr;			/* buffer descriptor: capabilities a
						 * receive accepts, 0 to ERX_MSG_CAPS */
	uint64_t	br[ERX_UTCB_BRS];	/* 58 buffer registers; read by no call */
	uint64_t	error;			/* why the last IPC failed, in detail */
	uint64_t	reserved;		/* zero */
	uint64_t	user[3];		/* thread-local words of liberx */
} erx_utcb_t;				/* 1 KiB */

typedef struct erx_vcpu {
	uint16_t	state;		/* ERX_VCPU_EVENTS: upcalls enabled; set by
					 * user mode, cleared by an upcall */
	uint16_t	saved_state;	/* state at the last upcall; resume restores it */
	uint16_t	sticky;		/* ERX_VCPU_PENDING: set by the kernel when it
					 * queues an event that no upcall took */
	uint16_t	reserved;	/* zero */
	uint64_t	label;		/* the label of the event the upcall delivers */
	uint64_t	entry;		/* where an upcall enters user mode */
	uint64_t	user[5];	/* words of liberx */
	erx_uframe_t	frame;		/* the user registers an upcall saves */
} erx_vcpu_t;

typedef struct erx_kupage {
	erx_utcb_t	utcb;		/* at offset 0 */
	erx_vcpu_t	vcpu;		/* at offset 1 KiB */
} erx_kupage_t;			/* padded to a page with zeros */
```

The kernel reaches both through its own mapping of the page. It reads a
field that user mode can write only through the shared-memory accessors,
once per decision, and moves message words from one UTCB to another only
through `erx_msg_copy`, which interprets nothing (K7). The page is mapped
before the thread first runs and goes only with the thread, so no upcall
and no message delivery can fault on it.

**Messages.** A message is a tag, which travels in a register, and the
message registers it describes:

```c
typedef struct erx_msgtag {
	uint64_t	raw;	/* bits 0-5 words, 6-11 items, 12-15 zero;
				 * 16-63 protocol, passed through untouched */
} erx_msgtag_t;

typedef struct erx_msg_item {
	uint64_t	desc;	/* sent: ERX_ITEM_MOVE and a rights mask;
				 * received: its erx_ktype_t and its rights */
	erx_cap_t	cap;	/* sent: the sender's value; received: the
				 * value in the receiver's table */
} erx_msg_item_t;
```

The words come first, at most 63, then the typed items, two registers
each and at most `ERX_MSG_CAPS` (4), so words and items fit the 63
registers together, as in Fiasco. A receive writes each item it received
back in its place, with the value the kernel assigned in the receiver's
table ([Passing capabilities](#passing-capabilities)). The buffer
descriptor says how many capabilities a receive accepts, where Fiasco's
names receive windows in the buffer registers, because the kernel assigns
every slot (K1); the buffer registers keep Fiasco's place and size, so the
UTCB is the 1 KiB the stopgap gives every thread.

A tag with a reserved bit set is refused with `ERX_EINVAL` before any
effect. A message from the kernel itself, a fault or exit record, reaches
its receiver through the space's fault gate, whose label the space's
creator chose, so no other sender can deliver under that label.

**IPC gates.**

```c
typedef struct erx_gate {
	erx_object_t	 obj;
	erx_spinlock_t	 lock;		/* thread, label, att_blocked and
					 * exits_dropped; a leaf */
	erx_thread_t	*thread;	/* the thread it is bound to, or NULL; on
					 * that thread's att_bound */
	bool		 dead;		/* its thread died: sends fail with
					 * ERX_EDEAD until it is bound again */
	uint64_t	 label;		/* given by its binder; reaches the receiver */
	erx_tqueue_t	 att_blocked;	/* senders waiting for it to be bound */
	erx_dlist_t	 att_faulting;	/* the spaces whose fault gate it is */
	uint64_t	 exits_dropped;	/* exit records dropped by their spaces'
					 * deletions; under lock; inspection
					 * reports it */
} erx_gate_t;
```

A gate is bound to one thread at a time, which receives every message sent
through it with the gate's label, as in Fiasco. A gate holds no messages:
a sender queues at the thread it delivers to, in that thread's
`att_senders`, and only while the gate is unbound does it wait in the
gate's `att_blocked`.

**IRQ objects.**

```c
typedef enum erx_irq_kind {
	ERX_IRQ_SOFT,		/* triggered by software alone */
	ERX_IRQ_LINE,		/* a device's interrupt line */
	ERX_IRQ_MSI		/* a line of the platform's MSI frame */
} erx_irq_kind_t;

typedef struct erx_irq {
	erx_object_t	 obj;
	erx_spinlock_t	 lock;		/* the fields below; held while taking the
					 * park lock of the group it is bound to */
	erx_irq_kind_t	 kind;		/* fixed at creation */
	erx_irq_state_t	 state;		/* changed only by erx_irq_step's result */
	erx_object_t	*target;	/* a thread or a group, or NULL; on the
					 * target's att_bound */
	erx_budget_t	*att_watched;	/* the one budget whose watch this is, or
					 * NULL; under its capability lock, then
					 * the budget's ([Budgets](#budgets)) */
	uint64_t	 label;		/* given by its binder; reaches the target */
	struct erx_irq	*next;		/* in its thread's senders or its group's
					 * ready list, while a delivery waits */
	uint32_t	 intid;		/* a line's interrupt id; 0 for ERX_IRQ_SOFT */
	uint32_t	 cpu;		/* the CPU its line is routed to */
	bool		 level;		/* a level-sensitive line */
} erx_irq_t;
```

An IRQ object is a doorbell: it carries nothing but its label, and at most
one delivery of it waits at its target, however often it fires
meanwhile. Software triggers, interrupt lines and MSIs drive the same
object through one state machine ([IRQ objects](#irq-objects)), so a
device's interrupt, a lane's doorbell and a worker's signal reach a
thread or a group the same way. A lane's doorbell is an IRQ object that
the system domain creates with the connection, binds to the consuming
domain's group, with `SIGNAL` on that group, under a label the consumer's
runtime learns with the connection, and installs in the producer with
`TRIGGER` alone. The system domain is every domain's creator, so its
install is not bound by the pass sets (**The creator's rule** in
[Passing capabilities](#passing-capabilities)): `TRIGGER` alone is its
own choice of mask, and with it the producer can ring the doorbell and
do nothing else with it. The kernel adds nothing for connections
([design-domains.md](design-domains.md#connections)).

**Umtx words** have no object: a waiter is queued in a hash bucket keyed
by the word's key, the memory object that the word's mapping names,
private memory's object included, and the word's offset in it. A
bucket's lock is a leaf that may be taken inside that object's lock
([Umtx](#umtx)).

### Resources, DMA windows and consoles

A **resource** is authority over device addresses, interrupt lines and
IOMMU streams, never over RAM. The root resource lists every device node
the boot found in the device tree except those the kernel keeps, each with
its path, its first compatible string, its register ranges (at most
eight) and its interrupt lines (at most eight); for a PCIe host bridge it
adds the bridge's memory windows from `ranges` and the map from requester
ids to IOMMU streams of its `iommu-map`. `erx_resource_carve(budget,
resource, kind, selector)` derives a narrower resource:

| Kind | Selector | What the carved resource names |
| --- | --- | --- |
| `ERX_CARVE_DEVICE` | an entry's index | that device, with everything the entry lists |
| `ERX_CARVE_RANGE` | a page-aligned range | the part of the resource's register ranges, or of a bridge's memory windows, inside the range: a PCIe function's BAR is carved this way |
| `ERX_CARVE_LINES` | a range of interrupt lines | those of the resource's lines |
| `ERX_CARVE_RID` | a PCIe requester id | the function with that requester id: the IOMMU stream the bridge's `iommu-map` gives it, if it lies on a fixed bus (**Requester identity** below), from which a DMA window is created, and the authority to create its MSIs |

A carved resource never exceeds its parent, so authority over devices only
narrows. A device is **confined** when it has a stream, which only a PCIe
function on a fixed bus that its bridge's `iommu-map` covers has, and
**unconfined** otherwise. The kernel reads a bridge's properties to carve
and never touches its configuration space: the bridge is a device like any
other, and its driver, the PCIe enumerator in the PCIe domain, holds
the configuration window as an ordinary register range
([design-system.md](design-system.md#devices)).

**Requester identity.** An IOMMU picks the window for a request by the
requester id the request carries, and nothing in a request shows which
function sent it, so a window confines its function only against functions
that cannot present an id of its stream. The functions that can present
each other's ids form an **isolation group**, which must share one stream,
and with it one window, one driver and one trust boundary. Which ids a
function can present is a fact of the platform's fabric, which its DMA
contract states ([design-platforms.md](design-platforms.md#dma)) and the
device table records as the machine's **fixed buses**: the PCIe buses on
which the fabric, not the function, sets each request's requester id, so
that only the function at a place on the bus presents that place's id, and
whose numbers no configuration write can change. `ERX_CARVE_RID` gives a
stream only to a function on a fixed bus, so every other function, and
every function of a machine whose contract fixes no bus, is unconfined and
its driver in the trusted base, and no window promises a confinement the
fabric cannot give. On QEMU `virt` the one fixed bus is its PCIe bridge's
root bus, where QEMU's model of the IOMMU takes each stream id from the
requesting device's place; the boards fix none.

**The devices the kernel drives** are named in one table, generated from
`hw/kernel_devices.txt`: by compatible string and role, the interrupt
controllers and MSI frames, the timer, the real-time clock, the IOMMU,
and the boards' random generator, watchdog and firmware mailbox
([design-platforms.md](design-platforms.md#the-devices-the-kernel-drives)
lists each platform's). Every list of these devices in erXos's documents
and code is generated from that file or points at it. At boot the kernel
binds each entry it finds to its node, and keeps the pages the node's
registers occupy, rounded out to whole pages. The early console is not
in the table: the platform's kernel build fixes its kind and address,
and the kernel writes that UART only by polling, during boot and at a
panic or the machine's end, after stopping the other CPUs, and never
reads a byte from it, so its pages enter the root resource and the
console's driver in the system domain owns the UART otherwise
([Console, log and panic](#console-log-and-panic)). No node whose
registers touch a kept page enters the root resource, and the boot log
names each node left out; on the Raspberry Pi 4 these are devices erXos
does not use, so no driver can reach the firmware
([design-platforms.md](design-platforms.md#the-devices-the-kernel-drives)).

A **DMA window** binds one IOMMU stream to an I/O address space of its
own: translation tables in the format the IOMMU shares with the CPU, a
budget that pays for them, the page of the platform's MSI frame mapped at
`ERX_DMA_MSI_IOVA` so the device's MSIs pass translation, and an IRQ
object triggered on faults of the stream
([DMA and the IOMMU](#dma-and-the-iommu)).

The **early console** is not an object: no capability names it and no
call reaches it. It is the one UART the kernel writes, for its own log
during boot and for the panic report and the machine's last line
([Console, log and panic](#console-log-and-panic)).

### Per-CPU state

```c
typedef struct erx_cpu {
	erx_thread_t	  *running;	/* the thread on this CPU; the idle thread if none */
	erx_thread_t	  *idle;	/* waits for interrupts and runs reaper steps */
	erx_runq_t	   runq;	/* ready queues by urgency (design-scheduler.md) */
	erx_timer_wheel_t  timers;	/* deadlines: waits, grace, refills, slices */
	erx_reqq_t	   requests;	/* cross-CPU requests: MPSC, applied in order */
	erx_rcu_list_t	   rcu;		/* puts and record frees queued on this CPU,
					 * each waiting for its grace period */
	_Atomic uint64_t   sync_seen;	/* synchronisation rounds taken */
	erx_trace_ring_t   trace;	/* written only by this CPU */
	erx_regs_t	   stopped;	/* registers saved when stopped by a panic */
	uint8_t		  *panic_stack;	/* 16 KiB with a guard page */
	uint64_t	   hwid;	/* the CPU's hardware identifier */
	uint32_t	   index;	/* 0 .. ncpus - 1; the boot CPU is 0 */
	bool		   online;
} erx_cpu_t;
```

A CPU has no kernel stack of its own: every entry runs on the kernel stack
of the thread it interrupts or that called, and the idle thread, which
has one like any thread, is what runs when nothing else does. The panic
stack is the one exception, used only once the machine is ending. Only
the CPU itself writes its record, except the request queue, to which other
CPUs append with release stores, and `sync_seen`. The panic path finds its
record from the CPU's hardware identifier through a table written at boot
and trusts no pointer.

## Algorithms and behavior

### Boot

The kernel image follows its architecture's boot protocol
([design-arch-aarch64.md](design-arch-aarch64.md#boot-entry)): a header
the loader reads, an entry in kernel mode or a more privileged mode with
the device tree's physical address in an argument register, and the boot
image inside the kernel's own file or, in the two-file form, as the
initrd ([The bootable file](#the-bootable-file)), all placed where the
loader chooses, so the kernel reads every address it is given and assumes
none ([measured](research-baselines.md#boot-conventions)). Every loader
erXos boots from (QEMU's `-kernel`, U-Boot, a board's firmware)
implements the same protocol, so no step is specific to one loader
([design-platforms.md](design-platforms.md#boot)).

1. **Entry, translation off, position independent.** Save the device
   tree's address. The kernel file is padded to the size its header
   declares, so a loader that ignores the header still places nothing over
   the zero-initialised data. If the device tree's header (its magic and
   `totalsize`) is wrong or places the tree over that data, which zeroing
   would destroy, stop with a message on the early console, which the
   kernel writes from this step on at the address its platform build
   fixes ([Console, log and panic](#console-log-and-panic)). If the CPU
   entered in a mode more privileged than kernel mode, route every
   exception of that mode to a handler that reports it on the early
   console and stops, write every register of that mode that controls the
   modes below it from one table generated from the system-register
   specification, so that it traps nothing kernel mode or user mode needs
   and keeps no value the firmware chose, and drop to kernel mode with
   every exception masked, never to return. The generator fails the build
   when the specification has such a register and the table has no entry
   for it (K15). Then zero the uninitialised data and switch to the boot
   stack inside the image, which the boot CPU's idle thread later keeps as
   its kernel stack. The binding names the registers and the reference it
   follows.
2. **Early device-tree pass** (`kernel/platform/fdt.c`). Check the header
   against `totalsize` and read only `/memory`, `/reserved-memory`, the
   memory reservation block, the nodes of the IOMMUs the kernel drives and
   `/chosen` (`bootargs`, `linux,initrd-start`, `linux,initrd-end`,
   `rng-seed`, `kaslr-seed`, `stdout-path`, and the two properties that
   name the boot slot, which firmware that boots one of two slots writes
   and the platform binding names,
   [design-platforms.md](design-platforms.md#data-model)). It walks the
   tree with `libfdt`, whose traversal is iterative and checks bounds at
   every step, behind this one file. The kernel keeps the boot value, its
   slot and any lease's deadline in its own data from here on; the crash
   record and the end funnel read them there, and the machine page is a
   copy of them. Until this step they hold `unknown`, slot `none` and no
   lease. When the boot value it derives is a
   trial, the kernel takes the machine lease here, before anything else
   can hang: it finds the watchdog's node, restarts the watchdog, which
   the firmware may already be running, and sets the lease's deadline from
   `erx.trial_deadline`, so a trial is supervised from the kernel's first
   decision ([Console, log and panic](#console-log-and-panic)). The steps
   until step 5 starts the kernel's timer, which then restarts the
   watchdog, take far less than the watchdog's timeout (an estimate that
   the boot probe checks on each board,
   [design-platforms.md](design-platforms.md#the-watchdog)). Malformed input
   stops the boot with a message on the early console. Once the pass has
   read `/chosen`, the kernel checks that `stdout-path` names a UART of
   the kind and at the address its platform build fixes, and otherwise
   stops the boot with a message naming the path, on the UART it was built
   for ([Console, log and panic](#console-log-and-panic)). Each platform
   has its own kernel build, which differs from the others only in the
   early console's kind and address
   ([design-platforms.md](design-platforms.md#uarts)). Either stop on a
   trial boot ends in a reset whatever `erx.panic` says, once the boot
   value is known.
3. **Translation tables.** Build an identity map of the image (to survive
   turning translation on), the kernel image at its link address in the
   kernel's half, the page of the early console's registers as device
   memory, for the kernel's own writes, and the direct map of RAM, which
   leaves out the kernel's text and read-only data, the boot-only
   section, the boot image and, on a board, the crash region
   ([design-platforms.md](design-platforms.md#the-crash-record)); the boot
   records the direct map's ranges, against which every umtx word's page
   is checked ([Umtx](#umtx)).
   Program the translation registers with these tables and an empty user
   table, write the kernel-mode control registers from zero plus the
   enables the binding lists ([Security](#security)), turn on translation
   and caches, branch to the kernel's half, and remove the identity map.
4. **Memory.** Check the IOMMU's handoff before reclaiming any memory.
   On a platform without an IOMMU there is nothing for the kernel to
   check: every DMA device is unconfined, and the loader's quiescence of
   every bus master, which the platform contract requires, is what keeps
   old DMA out of reclaimed memory. On a platform with one, verify its
   reset-state handoff by the register checks the binding names
   ([design-arch-aarch64.md](design-arch-aarch64.md#iommu)): every
   memory-access and notification facility of the IOMMU disabled, with
   its acknowledgement agreeing. An active, unknown or unhandled facility
   stops boot, since the kernel does not take over live firmware state.
   Then set global abort through the binding's memory-independent
   register transition to close future requests. For every bus master,
   confined or unconfined, the platform contract also establishes a
   completed drain or reset of outstanding DMA, including the IOMMU's own
   accesses; unknown or failed completion stops boot before allocator
   handoff ([design-platforms.md](design-platforms.md#dma)). Then seed the
   physical page allocator with RAM less the image, its tables, the device
   tree, the boot image, the reservation block and the reserved-memory
   nodes; then carve, before any budget exists, the per-CPU areas, each
   CPU's panic stack, the kernel stacks of the secondary CPUs' idle
   threads, the crash buffer, the machine page and the device-secret page,
   reading the crash buffer's region first for a previous crash record
   ([The root task](#the-root-task)).
5. **Devices.** Full device-tree pass. Initialise the interrupt controller
   and its MSI frame from their nodes, never from the CPU's feature
   registers, which do not always report them (under HVF they read as
   absent, [measured](research-baselines.md#accelerator-capabilities)).
   Then the timer, whose interrupt its node names; the
   real-time clock when present, read once for the wall clock, which
   otherwise starts at zero until the system domain sets it; the firmware
   interface that starts CPUs and ends the machine, by the conduit its
   node names, without which the boot stops; when present, the board's
   random generator, its watchdog, which the kernel reloads from its own
   timer once the firmware or a lease has started it and never stops ([The
   watchdog](#the-watchdog)), the firmware's mailbox and the platform's
   MSI frame; and the IOMMU when present, with every stream set to valid
   abort and every inherited configuration and translation cache
   invalidated with completed synchronization before translation is
   enabled ([DMA and the IOMMU](#dma-and-the-iommu)). These are the
   entries of the kernel's device table ([Resources, DMA windows and
   consoles](#resources-dma-windows-and-consoles)), and the platform
   binding lists each platform's compatible strings
   ([design-platforms.md](design-platforms.md#the-devices-the-kernel-drives)).
   Every other device node becomes an entry of the root resource, unless
   its registers share a page with a device the kernel drives; a PCIe host
   bridge's entry carries its memory windows and its `iommu-map`, and the
   kernel reads nothing behind the bridge, whose functions the PCIe
   enumerator finds ([design-system.md](design-system.md#devices)).
6. **Entropy and the device secret.** Seed the generator ([Interrupts,
   time and entropy](#interrupts-time-and-entropy)). Where the platform
   layer reads a board's key, code in the kernel's **boot-only section**
   reads it once, through the platform's firmware interface and with a
   deadline of 1 s, derives the device secret from it with HMAC-SHA-256
   keyed by the key, over the label `device_secret_label` of the ABI file, and
   writes the secret into the device-secret page; it then zeroes the key, the firmware's buffer
   that carried it and its own stack frames, with stores the compiler
   cannot remove, and cleans those lines to the point of coherency, so no
   copy of the key stays in memory. The firmware's buffer is the boot-only
   section's one page of data, which the direct map leaves out and no
   allocator ever receives, so the firmware writes nothing else. A read
   that misses its deadline leaves that page to the firmware, which may
   still complete the request: a completion after the deadline writes the
   key into that page alone, which the kernel unmaps with the section
   before it starts the root task and never maps or frees again, so a key
   that arrives late reaches no mapping and no other use of memory, and
   only code in kernel mode, which can read the key from the board in any
   case, could find it there until the next reset. Elsewhere, and when the
   read fails or times out or the key reads as never programmed, the page's
   status says which and its secret bytes stay zero
   ([design-platforms.md](design-platforms.md#device-secrets)). The
   boot-only section holds the key read and the derivation and nothing
   else; only this step calls into it, the kernel unmaps it before it
   starts the root task, and a relocation check fails the build on any
   other reference to it ([Chokepoint checks](#chokepoint-checks)), so no
   path after boot reaches the board's key again.
7. **Boot image.** Find it with `erx_boot_locate`
   ([The bootable file](#the-bootable-file)), validate its index
   ([The boot image](#the-boot-image)), map it read-only into the
   kernel's half, perform the cache maintenance the architecture requires
   before code in it may be executed, wrap its range in a physical memory
   object, and carve its table of file verdicts, every entry unchecked.
8. **Objects.** Create the root budget from every page left, the root
   group with every CPU in its cpuset and no quota, the root resource, the
   time page, and the previous crash
   record's object when step 4 found one.
9. **CPUs.** Start each `/cpus` entry other than the boot CPU, at most
   `erx.cpus` and none in deterministic mode, by the firmware's CPU-start
   call. An entry whose enable method the binding does not support, a CPU
   that the firmware refuses, and one that does not reach its idle thread
   within 100 ms stay offline, and the banner names them. Each secondary
   starts on its idle thread's kernel stack, leaves any more privileged
   mode as in step 1, enables translation with the same tables,
   initialises its interface to the interrupt controller, its timer and
   its per-CPU record, and enters its idle thread.
10. **Banner.** Print the build identifier, the boot image's index hash
    in hexadecimal, `development build: trusted
    code only` when the boot image says so, the DMA profiles the boot
    image allows, the entropy quality, the device-secret page's status
    (present, no key, never provisioned, or a read that failed), deterministic
    mode when it is on, and the CPUs and memory found.
11. **The root task.** Create the first space, which has no parent and no
    fault gate and is not a JIT space, and the root group's child
    `system`, uncapped until the root task gives it its grant
    ([The root task](#the-root-task)); map
    the root task's executable, the entry the boot image's `root_entry`
    names, from a slice of its own file with `erx_image_map`, the slice
    having checked the file's hash and manifest first and the boot
    stopping if the file fails or its manifest carries `ERX_IMAGE_JIT`
    ([Checking a file](#checking-a-file)); install the
    root capabilities; create its first thread, a worker in `system`, and
    start it ([The root task](#the-root-task)).

**Kernel virtual layout.** The kernel's half of the address space holds
global mappings, at addresses the binding fixes
([design-arch-aarch64.md](design-arch-aarch64.md#translation)):

| Region | Contents | Attributes |
| --- | --- | --- |
| direct map | RAM, less kernel text and read-only data, the boot-only section, the boot image and a board's crash region | normal, read-write, never executable |
| kernel image | the kernel's text, read-only data, data and zero-initialised data, and the boot-only section, its code and the page that receives the board's key, until the kernel unmaps it before it starts the root task (boot step 6) | text read-execute, and guarded where the architecture has branch-target protection; read-only data read-only; data read-write, never executable |
| device registers | the registers of the devices the kernel drives | device memory, read-write, never executable |
| boot image and per-CPU areas | the boot image, per-CPU areas, and each CPU's panic stack with a guard page | boot image read-only; the rest read-write, never executable |
| kernel stacks | every thread's kernel stack, in a slot of `ERX_KSTACK_SIZE` with an unmapped guard page below it, room for `ERX_KSTACKS_MAX` (2^20) slots | read-write, never executable |

Every user page is never executable in kernel mode, so the kernel never
executes user memory, and every kernel page is never executable in user
mode ([Port contract](#port-contract)).

### The root task

The system domain is the **root task**: the one user-mode task the kernel
starts, from the executable the boot image's `root_entry` names, which is
`liberx`'s root-task entry, with ERTS and the system release behind it
for a full boot or as a C17 native root for a development partial boot
([design-runtime.md](design-runtime.md#the-root-task-entry),
[design-system.md](design-system.md#the-root-task)). The kernel hands it
the root capabilities, and nothing else in the machine has authority the
root task did not pass on.

**Starting it** (boot step 11). The kernel creates the first space, which
has no parent and no fault gate, and the root group's child `system`;
maps the root task's executable from a slice of its own file with
`erx_image_map`; installs the root capabilities at the well-known slots
the ABI file defines; creates the task's first thread, a worker in
`system`, and starts it. The kernel holds no policy, so it creates that
group uncapped. Before starting other threads, the root task gives it
the grant the system configuration names, as policy caps every group;
it then
creates the root group's other children, `users` with the root group's
remainder among them, every domain and everything else as its policy
decides ([design-system.md](design-system.md#boot)). The boot image
carries the system configuration as one slice in the ABI file's record
format ([The boot image](#the-boot-image)), which the packer writes and
the root-task entry reads through the generated reader of that format,
so the grant of `system`, the `users` group's share and the
system principal's budget come from it before ERTS starts; ERTS later
reads the same slice for the rest of the configuration.

**The root capabilities**, at well-known slots of the root task's table
defined in the ABI file: the root budget (with `SPACES` and `CODE`), the
root group and its `system` child, the root resource, the boot image (with
`SYSTEM`), the time page, its own space and thread, the
**device-secret page**, read-only, in a layout of its own in the ABI file,
which no other space ever receives, since its rights ([Rights](#rights))
carry neither `DUP` nor `GIVE`, the **machine page**, and the **previous
crash record**, a read-only object of `ERX_CRASH_SIZE`, when the boot
found one (below), else `ERX_CAP_NULL` in its slot. Its own space and thread
and the two groups are installed with their kinds' whole default rights,
`DESTROY` among them, as any creation returns them. That is intended: deleting
its own space stops the first space, and deleting either group kills the root
task's threads, whose last exit stops it too; every such stop reaches
`erx_panic` (K31), as `erx_space_stop` on `ERX_CAP_SELF` does, so `DESTROY`
gives the root task no end of the machine it did not already have, and no way
to survive one.

The machine page is a read-only page in a layout of its own in the ABI file,
`erx_machine_page_t`, 4,096 bytes and page-aligned, zero after its last field:

| Offset | Field | Holds |
| --- | --- | --- |
| 0 | `lease_deadline_ns`, u64 | the machine lease's deadline on the monotonic clock in nanoseconds; 0 when no lease is held |
| 8 | `boot_value`, u32 | the boot value: `ERX_BOOT_VALUE_UNKNOWN` (1), `_NORMAL` (2) or `_TRIAL` (3) |
| 12 | `boot_slot`, u32 | its slot: `ERX_BOOT_SLOT_NONE` (0), `_A` (1) or `_B` (2) |
| 16 | `flags`, u32 | `ERX_MACHINE_DET`, deterministic mode, in which the watchdog is off; `ERX_MACHINE_CRASH_FOUND`, a previous crash record was found |
| 20 | `entropy_quality`, u32 | `ERX_ENTROPY_QUALITY_GOOD` (1), `_WEAK` (2) or `_FIXED` (3) |
| 24 | `memory_bytes`, u64 | the memory found |
| 32 | `cpu_count`, u32 | the CPUs found |
| 36, 40, 44 | `watchdog_period_s`, `watchdog_deadline_s`, `watchdog_boot_s`, u32 | the three values of `erx.watchdog` |
| 48 | `build_id`, 8 bytes | the build identifier |

The kernel writes every field before the root task starts and changes none
after: a lease is taken at boot and held until the machine ends ([The machine
lease](#console-log-and-panic)), and its deadline is one 64-bit word, so a
reader loads it once. The page holds no boot argument: the kernel alone reads
the command line ([Configuration](#configuration)). The boot value and its
slot are `unknown` with slot `none`,
`normal(slot)` or `trial(slot)` with slot `A` or `B`; a reader refuses any other pair,
so a page never written reads as no boot value at all.
The kernel derives them from the two `/chosen` properties that name the boot
slot ([design-platforms.md](design-platforms.md#data-model)), which the
boards' firmware and the QEMU harness write, mapping the partition to a
slot by the medium layout of the ABI file; it is `unknown` when either
property is missing or malformed, or the partition is not a slot
([design-storage.md](design-storage.md#system-updates)). It is not the boot
information page the system domain writes for each domain
([design-runtime.md](design-runtime.md#data-model)).

**Every domain is its child.** The system domain names its own space as
the parent of every domain's space it creates ([Creating
spaces](#creating-spaces)), so the rule that a space never outlives its
parent (K27) ends every domain, and every sub-space below one, when the
root task ends. No table outside the root task records which domains
exist, so nothing is left to reconcile after it.

**Its end is the machine's.** The first space has no fault gate and no
creator to report to, so three events end the machine instead, each after
a crash record (K31):

* a **fault** of a thread of the root task, which for any other space
  would become a fault record at the fault gate: it reaches `erx_panic`
  with the record as its cause;
* a **halt outside an ordered shutdown**: a stop of the first space by
  anything but `erx_machine_end`, whether `erx_space_stop` on
  `ERX_CAP_SELF`, the exit of its last thread, or a release, reaches
  `erx_panic` with the exit status as its cause. The ordered end is
  `erx_machine_end(res, how)`, with `POWER`, which the system domain's
  `liberx` calls at the end of an ordered shutdown, and with
  `ERX_END_PANIC` when ERTS exits any other way, so a crash dump's end is
  a crash record too ([Console, log and panic](#console-log-and-panic));
* a **missed deadline** of the watchdog ([The watchdog](#the-watchdog)).

Each goes through `erx_panic`, so each ends as `erx.panic` says
([Configuration](#configuration)): a reset through the firmware interface
in release builds, whose default is `reset`, and in development builds a
halt by default, so the record can be read on the console; on a board with
a hardware watchdog a halt becomes a reset within the watchdog's timeout,
since a halted kernel reloads nothing, and while a machine lease is held
every end resets (K19). There is no recovery protocol, no second instance
of the system domain, no re-grant and no incarnation, because nothing
survives the root task that would need reconciling; the machine boots
again and the new root task receives the record. A separate native root
task that restarts the system runtime is the alternative erXos does not
take ([Alternatives considered](#alternatives-considered)).

**The crash record.** Before any of these ends, and before a kernel
panic's report, the kernel writes one **crash record**, a layout of the
ABI file of at most `ERX_CRASH_SIZE` (16 KiB, an estimate: under 1 KiB of
fixed fields and the rest for the log's tail). It has two
**forms**, and the boot image's `ERX_PACK_DEVELOPMENT` flag
([Configuration](#configuration)) chooses which one a build writes:

* the **brief** form, a release build's, ends at `fault`: the cause, the
  program counter and fault address in the fault record, the build
  identifier, the boot value and its slot, so a crashed trial names the slot
  that failed, the uptime and the time since the last pet, and no register
  but the program counter, no stack and no text, so nothing the root task
  held, a passphrase it was checking included, survives a reset in it;
* the **full** form, a development build's, adds the registers, the
  backtrace and the text, among it the slogan and the start of the
  dump that the system domain's runtime writes to the kernel log before
  it stops
  ([design-runtime.md](design-runtime.md#the-root-task-entry)), and so
  may carry what the root task held, a passphrase among it, which is why
  the system domain shows a record only to holders of the system-shell
  facet (below).

```c
typedef struct erx_crash_record {
	uint64_t	magic;		/* ERX_CRASH_MAGIC */
	uint32_t	version;	/* ERX_CRASH_VERSION, 2 */
	uint32_t	length;		/* bytes used, header included: the
					 * offset of regs for BRIEF, at most
					 * ERX_CRASH_SIZE for FULL */
	uint32_t	crc;		/* CRC-32C of the bytes after this field,
					 * up to length */
	uint32_t	form;		/* ERX_CRASH_FORM_BRIEF or ERX_CRASH_FORM_FULL */
	uint32_t	cause;		/* ERX_CRASH_CAUSE_FAULT, _HALT, _WATCHDOG, _PANIC */
	uint32_t	cpu;		/* the CPU that wrote it */
	uint64_t	uptime_ns;	/* monotonic time at the end */
	uint64_t	since_pet_ns;	/* time since the root task's last pet, or
					 * since its start before the first */
	uint8_t		build_id[8];
	uint32_t	boot_value;	/* the boot value the kernel holds */
	uint32_t	boot_slot;	/* its slot, as on the machine page */
	uint32_t	nframes;	/* backtrace frames that follow; FULL and
					 * PANIC only, else zero */
	uint8_t		padding[4];	/* zero */
	erx_fault_t	fault;		/* FAULT: the fault record; HALT: the exit
					 * record; PANIC: the exception's cause,
					 * address and program counter, as the
					 * report names them; WATCHDOG: zero */
	/* The brief form ends here; the full form goes on. */
	erx_regs_t	regs;		/* FAULT: the thread's user registers;
					 * PANIC: the panicking CPU's registers;
					 * else zero */
	uint64_t	frames[64];	/* the backtrace, PANIC only */
	char		text[];		/* the panic message, then the kernel log's
					 * last records, newest last, each already
					 * escaped, up to length */
} erx_crash_record_t;
```

`boot_value` is at offset 56, `boot_slot` at 60, `nframes` at 64 and `fault`
at 72, so the brief form is 120 bytes; `regs` is at 120 and `frames` at 392,
so the full form's fixed prefix is 904 bytes. `boot_value` and `boot_slot` are
one of the pairs the machine page allows, from the kernel's own data, so a
record written before the page holds the same pair.

The kernel zeroes the **crash buffer**, the pages it carved at
boot step 4, which the platform layer places in a region that survives a
warm reset where the platform has one and in ordinary RAM elsewhere
([design-platforms.md](design-platforms.md#the-crash-record)), and writes the
record into it, so no padding byte holds what the buffer held before; it
cleans those lines to the point of coherency, and then prints the same fields and
text on the console as the panic report's first part, followed by the
record itself in the **crash frame**, so that a reader validates the
record rather than parses the report's prose. A newline before the header
line ends whatever line the report left open:

```text
--erx-crash-begin <form> <length>
<base64, 76 characters a line, the last line shorter>
--erx-crash-end
```

* `<form>` is `brief` or `full`, the record's form, and `<length>` the
  record's `length` in decimal: exactly `ERX_CRASH_BRIEF_SIZE` for
  `brief`, and from `ERX_CRASH_RECORD_SIZE`, the full form's fixed
  prefix, to `ERX_CRASH_SIZE` for `full`, so the header line alone bounds
  what follows.
* The payload is the record's first `length` bytes in base64 (RFC 4648,
  with padding), 57 bytes a line, so exactly `ceil(length / 57)` lines
  follow, at most `crash_frame_lines_max` (288), each of the full line
  length but the last, and the end line follows the last one. No other
  output interleaves with the frame: the writer runs after every other
  CPU has stopped.
* The record's own `crc`, CRC-32C of the bytes after the `crc` field up to
  `length`, is the frame's integrity check; the fields before it,
  `magic`, `version` and `length`, the reader checks by value, so there
  is no second checksum.
* The C reader, `kernel/core/crash_read.c`, shares a fuzz target with the
  writer over both forms; the harness's reader,
  `tools/lib/erx/crash_frame.rb`, is written apart from it, has a fuzz target
  of its own and gives the same answer on mutated frames. Each refuses the
  header line before reading
  a payload line when the form or the length is outside these rules,
  reads exactly the lines the length names, and accepts the record only
  if `magic`, `version`, `form` and `length` equal the frame's, the CRC
  matches, `cause` is one of the four, `cpu` is below `ERX_CPU_LIMIT`,
  `boot_value` and `boot_slot` are one of the machine page's pairs, the
  padding is zero,
  `nframes` is at most 64 and zero unless the form is full and the cause
  `PANIC`, the fault record's `kind` is a declared kind for `FAULT` and is
  `exit` for `HALT`, the fault record is zero for `WATCHDOG`, and in the
  full form `regs` is zero unless the cause is `FAULT` or `PANIC`, `frames`
  is zero past `nframes`, and every byte of `text` is printable ASCII or a
  newline, as escaped text is. A frame that ends before its lines or before the end
  line is reported as `truncated`; a line that is not base64 of the
  expected length, a second header line inside a frame, or any failed
  check as `corrupt`, with the lines kept; and no such boot passes a K31
  case.
* The ABI file declares `crash_frame_begin` and `crash_frame_end`, the
  marker strings, `crash_frame_line` (76) and `crash_frame_lines_max`
  (288), and `cpu_limit`, one more than the highest CPU a cpuset can name;
  `ERX_CRASH_BRIEF_SIZE` and `ERX_CRASH_RECORD_SIZE` are the generated sizes
  of the two layouts.

How each kernel carries the frame to its console is its binding's
([design-stopgap.md](design-stopgap.md#the-watchdog-the-crash-record-and-the-console)).
Every byte of text
in the record passed `erx_log_escape` when it entered the log, and the
report escapes everything else it did not write.

`erx_crash_record_write` is the one writer. It cannot refuse, since nothing
can report a refusal at the machine's end, so what it writes always passes
the reader's checks: an input that contradicts itself, a cause outside the
four, a CPU past the limit or a fault record the cause does not allow, is a
kernel bug and is written as `PANIC` rather than blamed on the root task; a
boot pair outside the machine page's is written as unknown; a form outside
the two is written as brief, and the brief form never reads the registers,
the backtrace, the message or the log. The message passes `erx_log_escape`;
the log's newest whole lines that fit follow it, each read through the
log's own check of a record, since a panic may have stopped a CPU halfway
through an append, and the walk has a bound of its own, since a wild store may
have reached the log's counters.

At boot step 4 the kernel reads the region before it carves the buffer. A
record that passes the reader's checks, and whose form is
the one the running build writes, is the **previous crash record**: the
kernel copies it into fresh pages wrapped in a read-only physical memory
object, hands that object to the root task among the root capabilities,
and the machine page says one was found. It then zeroes the whole region,
whatever the region held, so a record is reported once and a release build
never hands on, or keeps, a full record that a development build left. The
decision, `erx_crash_previous_length`, is a pure function over the
bytes, bounded by `ERX_CRASH_SIZE`, with a fuzz target over both forms,
since the region is memory that firmware and the previous boot wrote. The
system domain shows the record in the inspector after the reboot, to a
holder of the system-shell facet alone
([design-live.md](design-live.md#inspection)).

### The watchdog

The kernel drives two watchdogs, one timer each with one owner each: its
own, which guards the system domain's runtime, and the board's, which
guards the kernel.

**The kernel's watchdog.** Its period `P`, its deadline `D` after a pet and
its boot deadline `B` are the boot argument `erx.watchdog=P,D,B`, 1 s, 5 s
and 60 s by default ([Configuration](#configuration)), and the machine
page carries all three, so the root task reads what it must do. The kernel
**arms** the watchdog when it starts the root task, with the deadline `B`
seconds ahead: ERTS's boot, which takes seconds on a board and longer
under TCG, races `B` alone, and a hang during it ends in a reset like any
other hang. `erx_watchdog_pet(res)`, with `POWER` on the root resource,
sets the deadline to the current time plus `D` when it is on time, which
it is up to and including the deadline instant; a later pet moves
nothing, a pet before the root task starts is ignored, and a repeated
start never re-arms, so nothing extends a deadline but an on-time pet.
The call never waits and allocates nothing, and since no carved resource
carries `POWER`, only the root task can pet. A deadline that would lie
past the end of the clock's range saturates at that end and is never
reached. A timer of the kernel's own checks the deadline once a second,
and only that tick ends the machine: the first tick past a deadline that
no pet moved is `erx_panic` with the cause `ERX_CRASH_CAUSE_WATCHDOG` and
the time since the last on-time pet, or since the root task's start
before the first, the crash record first, as for a fault of the root
task ([The root task](#the-root-task)). A boot that does not
reach its first pet within `B` is a hang like any other and ends the same
way. The harness sets `B` and `D` larger for TCG runs, and the boot probe
on each board checks that the time to the first pet fits `B`
([design-platforms.md](design-platforms.md#verification-and-testing)).
The system release's `erx_watchdog` process pets it at period `P`, only
after each system service it lists, the domain service and the device
service at least, has answered a liveness call within the period: a
service that does not answer is killed and its supervisor restarts it,
and a runtime that cannot run the process misses the deadline, which is
this end. Under a development manifest's partial boot, where no ERTS
runs, the root-task entry pets ([design-system.md](design-system.md#boot)). `erx.watchdog`
has no off value: the watchdog is **off** only in deterministic mode
(`erx.det=1`), where the root task's start turns it off instead of
arming it, a pet is accepted and sets no deadline, and the machine page
says so, so the system release runs unchanged; release builds refuse
deterministic mode.
The decision is one pure function, `erx_watchdog_step`, over the states
off, unarmed and armed with a deadline, and the events start of the root
task, pet and tick, whose actions are arm, reload the board's watchdog,
or end; it is explored exhaustively on the host (K31).

**The board's watchdog.** Where a board has a hardware watchdog
([design-platforms.md](design-platforms.md#the-watchdog)), the kernel
reloads it from the same timer, at least once a second against the board's
timeout, from the moment the firmware or a machine lease has started it,
for as long as the kernel runs, and never stops it. It covers what the
kernel's watchdog cannot: a kernel that stops taking interrupts, or that
has halted after a panic, resets within the board's timeout (K19). The
hardware watchdog is never reloaded from the root task's pet: a pet-fed
hardware watchdog could fire before the kernel's deadline, with no crash
record, and would make ERTS's boot race the board's timeout.

### The boot image

The boot image is an indexed archive of every file and executable image
the machine starts with, in erXos's own format `ERXPACK` version 2. The
host packer (`tools/erx pack`, Ruby) writes it, and the kernel never
trusts it unchecked: the boot validator checks its index once, at boot,
and each file is checked before its first use
([Checking a file](#checking-a-file)). All integers are little-endian.
Every file starts on a page of its own, so each page of file
data belongs to exactly one file and any run of files can be handed out as
whole pages; and every file carries the system mark or not, which the
packer sets exactly on the files of the system release: the root task's
executable and the system domain's release. The packer sets the seal mark
exactly on the files of the vault's release, and the system domain maps
the vault's sealing page into a domain exactly when
the release slice it is created with is that run
([design-system.md](design-system.md#the-vault)), so the right to the
sealing secret follows from the image, never from a request; the kernel
only validates the mark. The image carries the system configuration as
one file in the ABI file's record format; the root-task entry reads it
through that format's generated reader before ERTS starts, and the system
services read the same file ([design-system.md](design-system.md#boot)).

**A two-level hash.** Every byte of the archive belongs to exactly one
**run**: the **index run**, from offset 0 to the first page boundary
after the string table, which holds the header, the entry table and the
string table; or one entry's **file run**, its data and the zero padding
up to the next page boundary. Each entry records the hash of its file
run, and the header records the hash of the index run, computed with the
header's own hash field read as zeros. The header's hash therefore
commits to every byte of the archive: it is the image's one identity,
which the banner prints, the host tool compares with the image it packed,
and a later signature can cover. The format version names the algorithm:
version 2 hashes with BLAKE3 in its default, unkeyed mode with a 32-byte
output, so a change of algorithm is a change of version.

```text
header, 96 bytes, at offset 0
  u8[8]   magic          "ERXPACK\0"
  u32     version        2: this layout, hashed with BLAKE3
  u32     flags          ERX_PACK_DEVELOPMENT, ERX_PACK_UNCONFINED_DMA; others zero
  u64     total_size     bytes of the archive, a multiple of 4,096
  u32     nentries       1 .. 65,536
  u32     entry_size     64
  u64     entries_off    96: entry table immediately after the header
  u64     strings_off    96 + nentries * entry_size: after the entry table
  u32     strings_size   at most 4 MiB
  u32     root_entry     index of the root task's executable
  u8[8]   build_id       identifies the build; the host tool compares it: the
                         first 8 bytes of the index run's BLAKE3 hash with
                         this field and index_hash read as zeros
  u8[32]  index_hash     BLAKE3 of the index run, with these 32 bytes read
                         as zeros
entry, 64 bytes, sorted by path, strictly ascending as byte strings
  u32     path_off       into the string table
  u16     path_len       1 .. 4,096
  u8      kind           1 file, 2 executable image
  u8      flags          ERX_ENTRY_SYSTEM: a file of the system release;
                         ERX_ENTRY_SEAL: a file of the vault's release; others zero
  u64     data_off       a multiple of 4,096
  u64     data_size
  u64     manifest_off   image: the manifest's offset from data_off; file: 0
  u8[32]  file_hash      BLAKE3 of the entry's file run: data_size bytes
                         from data_off, then zeros to the next page boundary
```

**Integrity, not authenticity.** The hashes detect a damaged medium, a
torn or cut-short write, a loader that placed less than the whole image,
and an archive paired with a first stage it was not packed with. Whoever
can write the medium can also write matching hashes, so they authenticate
nothing. Authenticity comes only from the platform's trust root: on a
board with secure boot on, the boot ROM's check of the signed slot, which
holds the bootable file and with it the header's hash
([design-platforms.md](design-platforms.md#trust-in-the-boot)); on QEMU,
the host that chooses the file; elsewhere, nothing. Because the header's
hash commits to every file, a signature over it alone would extend a
platform's trust to every file without rechecking the whole image at
boot; such a signature is not part of this design.

The validator (`kernel/core/pack.c`) reads only the index run, in one
pass with no recursion, bounded by `nentries` and the total path bytes.
Its caller supplies the hasher's state and 16 KiB of scratch for the
bounded path-prefix stack
described in
[File-prefix exclusion](design-abi.md#file-prefix-exclusion); it allocates
nothing and puts no input-sized array on the kernel stack:

1. The archive's length is the length the locator found
   ([The bootable file](#the-bootable-file)); `total_size` equals it.
2. The header's fields hold their stated values and ranges; a version
   other than 2 is refused with a diagnostic naming the version found and
   the one expected, before step 1 or any other check uses a field after
   the version. The entry
   table starts immediately after the header and the string table
   immediately after the entry table; their declared offsets equal those
   derived positions. The index run, which ends at the first page boundary
   at or after the string table's end, lies inside the archive, with every
   product and offset-plus-size computed with overflow checks.
3. **The index hash.** The BLAKE3 hash of the index run, with
   `index_hash` read as zeros, equals `index_hash`. No entry or path is
   read before this check passes, so a damaged index is refused as
   damaged, not by whichever structural check its damage happens to trip.
   Every byte of the index run after the string table is zero.
4. The paths fill the string table in entry order with nothing between
   them, so the paths' total length is `strings_size`, and each is valid: UTF-8 with
   no byte below `0x20` and no `0x7f`, components separated by `/`, no
   leading or trailing `/`, no empty component, no `.` or `..`.
5. Paths ascend strictly, so no path appears twice. The bounded
   file-prefix stack rejects a path that begins with any earlier file's
   path followed by `/`, so no file is also a directory. The comparison
   includes nonadjacent entries: byte order can place `a-foo` between
   `a` and `a/b`.
6. Each entry's data lies inside the archive, and the entries' data appear
   in entry order with nothing between them but padding to a page: the
   first starts where the index run ends, and each other at the first page
   boundary at or after the end of the previous one's data. So no two
   files share a page, no file shares a page with the index, a run of
   entries is exactly a run of pages, and the archive, which ends at the
   first page boundary at or after the last entry's data, is exactly the
   index run followed by the file runs, each byte in one run.
7. The entries that carry `ERX_ENTRY_SYSTEM` form one contiguous run of the
   table, `root_entry` is an executable among them, and the system
   configuration's path names a file among them; the entries that
   carry `ERX_ENTRY_SEAL` form one contiguous run, possibly empty, that
   shares no entry with the system run; and no other flag bit is set.

A failure stops the boot with the check that failed and the entry's index.
The validator reads no file data, so its cost follows the index's size,
not the image's. Once validated, the boot image never changes (K16).
Files are stored uncompressed, so runtimes map and load them in place.
Starting every file on a page costs about 2 KiB of padding per file on
average, a few MiB for an image of a few thousand files (an estimate).
The validator builds for the host and has a fuzz target
([Tests of the boot image](#tests-of-the-boot-image)).

**What a domain can map.** No space can map the boot image whole: its
object's ceiling is empty, so a mapping of it is refused whatever its
capability carries (K4), and it is not one of the immutable objects that
parent copy-on-write children. Its capability carries every right a
slice is created with but `DESTROY`, and never `WRITE`, since a slice's
rights are the intersection with it ([Rights](#rights)); a copy passed
at a rendezvous keeps only the pass set, without `CARVE` or `SYSTEM`,
and so slices nothing (K24).
Domains get **slices**: `erx_image_slice(budget, image, first, count)`
checks every unchecked file of a run of entries, then makes a physical
memory object over the run's pages, its record charged to `budget`; it
refuses a run that includes a system file unless the image capability
carries `SYSTEM`, and a run that includes a refused file with
`ERX_ECORRUPT`. The system domain keeps the
image capability and makes every slice itself, using `SYSTEM` only for its
own release, so other domains receive slices of their own releases only,
and no user mapping ever reaches the index.

**Reading the index.**
`erx_object_info(image (INSPECT), ERX_INFO_IMAGE_ENTRY, index, window)`,
on the image or on a slice, writes one validated entry into the caller's
memory window ([Arguments and results](#arguments-and-results)): its path,
kind, size, system mark, file hash, and its offset within the slice; on a
slice, `index` counts from the slice's first entry. The system domain
finds the
runtime images and each domain's release this way, and a runtime lists
its release's files from its own slice, so the index is read only
through the validator's results and never mapped. The boot image is not
confidential from whoever holds the medium, so it holds no secret and no
check of a credential: passphrases are checked only against the vault's
sealed files, on the vault's own partition
([design-system.md](design-system.md#the-vault)), and the only keys the
image carries are public ones, such as the release key's public half,
which checks update manifests
([design-storage.md](design-storage.md#system-updates)), in files of the
system release
([design-domains.md](design-domains.md#principals-sessions-and-quotas)).

### Checking a file

`erx_pack_file_check(view, entry)`, a pure function
of `kernel/core/pack.c`, reads the entry's file run once: it computes the
run's BLAKE3 hash and compares it with `file_hash`, checks that every
byte of the run after `data_size` is zero, for an executable image
runs the manifest check of [Image manifests](#image-manifests), and for
the system configuration opens it with the manifest reader and compares
its development flag with the image's. Its
verdict is good, or refused with the check that failed. Every file passes
this one function before its first use, and its first user decides where:

| File | Checked by | When |
| --- | --- | --- |
| the stopgap's kernel, the entry at `boot_kernel_path` | `bootstrap` | after the validator, before `erx_elf_plan` reads the entry ([design-stopgap.md](design-stopgap.md#boot-handoff)) |
| the root task's executable, `root_entry` | the kernel | at boot step 11, by the slice of its file, before `erx_image_map` reads its manifest; the boot also refuses a root image whose manifest carries `ERX_IMAGE_JIT` here |
| every other file | the kernel | at the first `erx_image_slice` whose run includes it |

So no file is read or mapped before its check, by construction rather
than by a list of callers: no space can map the image whole (K16), every
mapping of a file's pages is made from a slice, the kernel reads file
data only through a slice, `bootstrap` reads only the one entry it
checked, and `erx_image_slice` makes a slice only over entries whose
verdict is good. A file that fails its check is refused and never
mapped: the slice fails with `ERX_ECORRUPT`, a status of its own in the
ABI file's list, the kernel log names the entry's index, its path through
the log's escaping function and the check that failed, and every later
slice that includes the entry fails at once with the same status. At
boot, a failure of the root task's executable or the stopgap's kernel
stops the boot the same way. The system domain treats `ERX_ECORRUPT` as
the failed start of the domain or program that needed the file and never
retries it, since the image does not change.

**The kernel hashes with portable code.** The kernel executes no FP or
SIMD instruction, so the kernel and `bootstrap` build BLAKE3's portable C
implementation alone; its SIMD paths are not built into either, and the
kernel's build check for FP and SIMD instructions would refuse them. On
the target no user-mode code checks the boot image, since a check made
after a mapping could not keep a damaged file unmapped; the host tools,
which run in user mode, build the SIMD paths. Scalar BLAKE3 runs roughly
two to three times as fast as scalar SHA-256 (an estimate, which the boot
benchmark measures on each platform).

**Verdicts.** The kernel keeps one verdict byte per entry, unchecked,
good or refused, in a table it carves with the boot image's object at
boot step 7, before any budget exists: `nentries` bytes, at most 64 KiB.
A verdict moves only from unchecked to final, and since the image never
changes every check of one entry reaches the same verdict, so the table
needs no lock: two slices that check the same unchecked entry at once
each hash it and store the same value, at the cost of hashing it twice,
and only the system domain, the one holder of the right to slice, can
cause that. A slice checks the unchecked entries of its run in entry
order, in parts of at most 64 KiB between preemption points (K13),
holding a reference to the image object as a range call does. The
hasher's state, about 1.9 KiB in the official implementation, lives in
one page that the call charges to `budget` and releases before it
returns, so no kernel stack holds it. A file is hashed once per boot,
when it is first sliced, and a file that is never used is never read.

### The bootable file

The packer emits the boot image in one of two forms. The **first stage**
is the code the loader enters: erXos's kernel, or on the stopgap
`bootstrap`.

* **The single file**, the default and the only form a slot or a board
  carries: the first stage's image, which starts with the header of the
  architecture's boot protocol, then zeros up to a page boundary, then the
  archive, unchanged, to the end of the file. QEMU boots it with `-kernel`
  alone, and the Raspberry Pi firmware loads it as the slot's kernel file
  alone ([design-platforms.md](design-platforms.md#boot)).
* **The two-file form**, for debugging under QEMU: the first stage as
  built, booted with `-kernel`, and the archive as `-initrd`, so one
  kernel build can be run against archives packed after it and the file
  QEMU runs is the build's own output, byte for byte.

The archive is byte-identical in both forms, so its header's hash is the
same.

**The locator.** The first stage carries a 32-byte **boot locator** at
the offset its architecture's binding fixes, inside the part of the image
that the boot protocol's header leads
([design-arch-aarch64.md](design-arch-aarch64.md#boot-entry)):

```text
boot locator, 32 bytes, aligned to 8
  u8[8]   magic          "ERXBOOT\0"
  u32     version        1
  u32     zero
  u64     archive_off    from the first stage's first byte; 0: no archive
                         in this file
  u64     archive_size   bytes of the archive; 0 exactly when archive_off is 0
```

As built, both fields are zero. Making the single file, the packer writes
exactly two things into the first stage's bytes: the locator's two
fields, and the image size the boot protocol's header declares, which it
sets to the whole file's length. A loader that honours that size keeps
the archive clear of everything it places, and one that ignores it still
places nothing over the archive, since the archive lies inside the file,
as the kernel file's padding does for its zero-initialised data
([Boot](#boot)).

`erx_boot_locate`, a pure function of `kernel/core/pack.c` that both
first stages call before anything reads the archive, decides where the
archive is from the locator, the first stage's load address and linked
end (a constant of its build that includes its zero-initialised data),
the image size its header declares, the initrd range that `/chosen`
names, and the device tree's memory ranges, its own extent and the memory
reservation block:

1. A locator whose magic, version or zero field is wrong stops the boot.
2. With `archive_off` zero, the archive is the initrd; no initrd stops
   the boot with `no_boot_image`.
3. With `archive_off` nonzero, an initrd as well stops the boot with
   `two_boot_images`, so the machine never boots an archive other than
   the one it was meant to; `archive_off` is a multiple of 4,096 at or
   after the first stage's linked end, so the archive overlaps none of
   the first stage's code, data or zero-initialised data; and
   `archive_off + archive_size`, computed with an overflow check, is at
   most the declared image size.
4. In either form the archive starts at a page-aligned physical address
   and its range lies inside one memory range of
   the device tree and overlaps neither the device tree, nor the
   reservation block, nor the first stage's extent.

The locator lies in the first stage's own image, which nothing writes
after the loader placed it, and is read once into local values while only
the boot CPU runs. The validator then runs over the range found, with its
length: a single file that its loader or its medium cut short fails the
validator's length or index check, or the file check of a file the cut
reached.

**Choosing the form.** `tools/erx pack` writes the single file;
`tools/erx pack --two-file` writes the first stage and the archive as two
files, and the QEMU harness boots either form. The medium layout, the
slot writer and every board take only the single file, and the packer
refuses the two-file form for a slot image.

**Reproducibility.** The single file is a pure function of the first
stage's bytes and the archive's: the first stage as built with its two
locator fields and its declared size written, zeros up to `archive_off`,
and the archive. Both forms are byte-identical across two builds from the
same inputs (`make check-reproducible`), and the archive inside the
single file is byte-identical to the two-file form's archive.

**Execute in place.** The phrase has two meanings, and the format is
ready for the first:

* *User code run from the image's own pages.* `erx_image_map` already
  maps read-only and executable segments from the slice
  ([Image manifests](#image-manifests)), so a boot image's code runs from
  the image's pages with no copy, wherever those pages are, and only
  writable segments become private memory, filled from the slice at first
  touch. The canonical storage is what allows this: each segment's
  payload starts on a page of its own and its `mem_offset` is
  page-aligned, which the manifest check verifies, so a payload's offset
  in the archive and its virtual address agree modulo the page size; the
  ELF planner that the packer runs refuses a load segment whose address
  or file offset is not page-aligned, or whose file offset and address
  disagree modulo its alignment, with a diagnostic, and never rounds an
  unaligned start. The image's pages are immutable once validated (K16)
  and stay resident for the machine's life, since the image's object is
  never destroyed. What no loader does yet is leave the image on its
  medium: every loader erXos boots from copies the bootable file into
  RAM. The future option is a platform with memory-mapped flash or ROM
  holding the bootable file: the kernel would wrap the image's object over
  the medium's physical range, mapped read-only as normal cacheable
  memory, and slices, the file check and `erx_image_map` would work
  unchanged above it; `erx_exec`, which maps an executable file's code
  from its file object, read-only and executable
  ([design-programs.md](design-programs.md#what-a-program-can-start)), would
  serve a file system on such a medium the same way. No mapping changes
  form, so no mapping becomes writable and executable at once, and no new
  site maps code: `erx_image_map` and `liberx`'s loader stay the only
  ones. It would save the RAM the archive occupies, tens of MiB for a
  full image (an estimate), and the loader's copy at every boot. It would
  cost slower instruction fetch and first-touch fills on every cache miss
  to the medium, a check of each file that reads the medium, and a rule
  that nothing writes the booted slot's medium while it runs, since a
  flash part being programmed does not read back its data; the slot
  writer already writes only the spare. The Raspberry Pis have no
  memory-mapped boot medium, so the option applies only where a platform
  has one, as QEMU `virt`'s flash devices are.
* *First-stage code run from ROM or flash before memory is set up.* Only
  the first stage would need to be linked at a physical address, with its
  writable data in RAM; the single file is already the shape it would
  take, the archive following the first stage on the same medium. It is
  not designed further.

### Tests of the boot image

Each passing case is paired with a seeded failure that proves the code
under test ran.

| Case | Passes when | Seeded failure |
| --- | --- | --- |
| the index hash | an image the packer wrote validates, on the host and at boot | one flipped byte in the entry table, one in the string table and one in the index run's padding are each refused with `index_hash` before any structural check; the same flipped entry with the hash recomputed is refused by the structural check it breaks, which shows the hash check is what refused first |
| a file's hash | a slice of every file of a packed image succeeds, and the root task starts | one flipped byte in a file's data passes the validator, which reads no file data, and fails the first slice that includes the file with `ERX_ECORRUPT`, naming its index; a slice of its neighbour succeeds; a second slice of the damaged file fails without hashing again, which the check counter shows |
| a file checked at boot | the root task and, on the stopgap, the kernel start | one flipped byte in the root task's executable stops the boot at step 11 naming `root_entry`; one in the stopgap's kernel stops `bootstrap` before `erx_elf_plan` runs |
| a file run's padding | every file run's padding is zero | a fixture with a nonzero padding byte and a hash recomputed over it is refused with `padding`, which the hash alone would accept |
| concurrent checks | four threads on four CPUs slice the same unchecked file at once, each gets its slice, and the verdict is good | a checker seeded to store its verdict before it finishes hashing lets a concurrent slice of a damaged file succeed, which the test catches |
| the version | an image of version 2 validates | an image of version 1's layout is refused with `version 1, expected 2`; a version-2 image with its version field set to 3 and its index hash recomputed is refused by the version check, not by the hash |
| BLAKE3 | the kernel's portable build and the host tools' SIMD build both reproduce the official test vectors | one vector seeded with a wrong digest fails both builds |
| the single file | the single file boots under QEMU with `-kernel` alone, under TCG and HVF, on the stopgap and on erXos's kernel, and the banner's index hash equals the packer's | the same single file booted with an `-initrd` as well stops with `two_boot_images`; a locator whose `archive_off` points into the first stage's zero-initialised data is refused; a file cut one page short is refused by the validator |
| the two-file form | the first stage as built boots with the archive as `-initrd`, under TCG and HVF, with the same banner hash as the single file | the first stage booted without `-initrd` stops with `no_boot_image` |
| reproducibility | both forms are byte-identical across two clean builds, and the single file's archive equals the two-file archive | a packer seeded to write the time into the locator's zero field fails `make check-reproducible` |
| segment alignment | every executable the build packs passes the ELF planner, and each mapped segment's bytes equal the ELF's | an ELF fixture whose load segment's file offset is not page-aligned, and one whose offset and address disagree modulo the page size, are each refused by the packer with a diagnostic; with the planner's check removed the fixture packs, and the comparison of mapped bytes with the ELF's fails |
| fuzzing | the validator's fuzz target runs its configured budget clean under ASan and UBSan | the target recomputes the index hash after each mutation, so mutations reach the structural checks, and also runs `erx_boot_locate` over arbitrary locators, declared sizes and memory maps and `erx_pack_file_check` over mutated file runs; a seeded off-by-one in the locator's bound on the declared size makes the target abort within the budget |

### Image manifests

The kernel parses no ELF. For each user-mode executable in the boot image,
the packer writes a manifest derived from its program headers. The
stopgap's kernel, which `bootstrap` places before any kernel runs, is an
opaque file entry outside this user-mode mapping interface: `bootstrap`
plans its placement with `erx_elf_plan`'s kernel profile and copies only
what that plan names ([design-stopgap.md](design-stopgap.md#boot-handoff)):

```c
typedef struct erx_image_segment {
	uint64_t	file_offset;	/* from the entry's data_off; page-aligned */
	uint64_t	mem_offset;	/* from the image's base; page-aligned */
	uint64_t	file_size;
	uint64_t	mem_size;	/* >= file_size; the rest reads as zero */
	uint32_t	prot;		/* ERX_PROT_R, _RW or _RX; never W with X */
	uint32_t	flags;		/* ERX_SEG_GUARDED: map as branch-target guarded pages */
} erx_image_segment_t;

typedef struct erx_image_manifest {
	uint32_t	magic;		/* ERX_IMAGE_MAGIC */
	uint16_t	version;	/* 1 */
	uint16_t	nsegments;	/* 1 .. 8 */
	uint32_t	abi_version;	/* the ERX_ABI_VERSION it was built for */
	uint32_t	flags;		/* ERX_IMAGE_FIXED: linked at fixed_base;
					 * ERX_IMAGE_JIT: makes JIT objects */
	uint64_t	span;		/* bytes from base to end; below 4 GiB */
	uint64_t	fixed_base;	/* ERX_IMAGE_FIXED only; else 0 */
	uint64_t	entry;		/* offset from the base */
	uint64_t	phdr_offset;	/* program headers, from the base, for a C
					 * library that finds its TLS template
					 * through them */
	uint32_t	phnum;
	uint32_t	base_alignment;	/* required placement alignment */
	erx_image_segment_t segments[];
} erx_image_manifest_t;
```

Both layouts are fixed by the ABI file and pinned with `_Static_assert`.
The packer accepts static position-independent executables (`ET_DYN` with
no interpreter and no dynamic dependencies) and static executables linked
at a fixed address (`ET_EXEC`), for which it sets `ERX_IMAGE_FIXED`. It
sets `ERX_IMAGE_JIT` on the images the build declares as making JIT
objects, and on no other: the BeamAsm runtime image, which ordinary
domains run; the system domain creates a domain's space with
`ERX_SPACE_JIT` exactly when the domain's image carries it
([design-system.md](design-system.md#creating-a-domain)), so the right to
make code follows from the image, never from a request. **The root image
is not a JIT image.** For a full boot the root task's executable carries
the interpreter runtime, without BeamAsm, asmjit or any C++; a development
partial boot may use the native C17 root-entry image
([design-runtime.md](design-runtime.md#the-root-task-entry)); the boot
stops when the root task's executable carries `ERX_IMAGE_JIT`, which it
checks with the file before mapping it ([Checking a file](#checking-a-file)), and
the kernel creates the first space without `ERX_SPACE_JIT`, so no thread of
the system domain can create a JIT object (K8), and no view of code that
was written exists in the trusted base.

**Canonical image storage.** An executable entry starts with its manifest
at offset zero, alone on the first 4,096-byte page. The fixed prefix and
segment array fit that page; its unused bytes are zero. Segment payloads
follow in virtual-address order, each starting at the first page after
the preceding payload. The logical `file_size` and `mem_size` describe the
ELF load segment, not the storage padding. A read-only or executable
payload occupies `round_up(mem_size, 4096)` bytes: the packer copies its
`file_size` source bytes and zeroes the entire remainder. A writable
payload occupies only `round_up(file_size, 4096)` bytes, with zero page
padding; the rest of its memory is private zero-filled memory. A writable
segment with zero file bytes consumes no payload pages. No payload shares
a page with the manifest or another payload, and the entry ends exactly
at the final payload boundary.

The ELF planner discards zero-memory load segments and refuses unaligned
load addresses or file offsets with a diagnostic; it never rounds an
unaligned start into bytes outside the declared load. It bounds every
source range before copying. The whole pack plan computes the expanded
read-only tails and total output with checked arithmetic and rejects an
output beyond the caller's declared packing budget before allocation or
publication. This host resource budget is not another wire-format version.

**The manifest check**, which the file check runs on every user-mode
executable after its hash matched ([Checking a file](#checking-a-file)),
verifies:

* magic, version, ABI version, segment count, reserved zeroes and exactly
  the declared image, segment and protection flags;
* the canonical manifest/payload layout and every payload extent within
  the entry, including all required zero-filled bytes;
* nonzero logical memory lengths, `mem_size >= file_size`, page-aligned
  starts, and virtual intervals that do not overlap after their lengths
  are rounded to pages;
* a nonzero, page-aligned span below 4 GiB equal to the rounded end of the
  last segment, and an entry offset inside an executable segment's logical
  memory interval;
* each writable segment's memory length at most 64 MiB;
* a positive program-header count and the complete
  `phnum * architecture_program_header_size` virtual range, with checked
  arithmetic. Every byte of that range belongs to a readable segment's
  logical file-backed portion; stored zero padding and anonymous tails do
  not qualify. Coverage is checked across the at most eight ordered
  segments, without parsing any ELF header;
* a power-of-two base alignment, at least one page and representable in
  its `u32` field; a zero fixed base for a position-independent image, or
  a page-aligned fixed base above 64 KiB whose entire span lies in the
  architecture's user half. Fixed images have the canonical base alignment
  of one page.

For a position-independent ELF, the normalized virtual origin is the
minimum load address rounded down to the greatest of one page and its
load segments' `p_align` values. Each offset in the manifest is relative
to that origin. A mapped base aligned to `base_alignment` therefore makes
the ELF load bias, mapped base minus original origin, a multiple of every
load alignment; an unmapped leading virtual gap is permitted. A fixed ELF
uses its minimum load address as `fixed_base`, preserving its original
addresses. The ELF planner checks that each nontrivial `p_align` is a
power of two and that file and virtual addresses satisfy its congruence.

The planner preserves the original program-header bytes in their load
segments. Their virtual addresses retain ELF meaning for TLS; their
original file offsets do not name the normalized archive's payload offsets.
The checks have independent malformed fixtures for rounded overlap,
metadata/tail exposure, entry membership, and truncated or uncovered
program-header arrays.

`erx_image_map(space, image, entry)` finds `entry` in the validated index,
checks that it is an executable whose pages lie inside the slice `image`,
and reads its manifest: an `abi_version` other than the kernel's
`ERX_ABI_VERSION` fails with `ERX_ENOTSUP`. It places a position-independent
image at a random base aligned to `base_alignment` (fixed in deterministic
mode) and a fixed image at `fixed_base`, failing with `ERX_EEXIST` if that
range is in use. Read-only
and executable segments map the slice itself, so every domain given that
slice shares their pages and none can write them. Each writable segment, at
most 64 MiB, is private memory committed at once whose source is the
segment's first `file_size` bytes in the slice; its pages fill on first
touch, so mapping copies nothing, and bytes beyond `file_size` read as
zero. Segments marked `ERX_SEG_GUARDED` are mapped as guarded pages where
the architecture has branch-target protection
([design-arch-aarch64.md](design-arch-aarch64.md#optional-hardening)).
The call is all or nothing.

### Execution model and locking

**A kernel stack per thread.** The kernel follows Fiasco's process model.
Every entry into the kernel (a kernel call, a fault, an interrupt, an
asynchronous error) runs on the kernel stack of the thread that was
running, with interrupts masked. An entry from user mode first saves the
user registers into the thread's record; an interrupt taken in kernel
mode, at a preemption point inside a call, saves the interrupted kernel
registers as a frame on that stack, above the call's own frames, and
leaves the record's user registers, those the call entered with, as they
are. A call that must wait records what it waits for in the thread's wait
record and switches away; whoever ends the wait (a message, a reply, a
wake, a trigger, the timer) makes the thread ready, and it continues where
it stopped on its own stack. A call therefore ends in one of two ways: it
returns its status and results to the caller, or the thread does not come
back, because it exited, was stopped by a fault or died with its space.
Every call declares in the ABI file whether it may wait and the bound on
its work between preemption points (K13).

**A wait holds nothing.** A call that waits does all of its work before
it sleeps and keeps nothing alive across the sleep: no counted
reference, no lock of either kind, no result still to translate, no
frame whose contents matter. What survives the sleep is the thread's
wait record and its result, and completing a wait is one pure function,
`erx_wait_complete`, which writes the result registers from the wait's
outcome and runs the return check; every wake path calls it, whether a
message, a reply, a wake, a trigger, a timeout or a stop ends the wait,
so the woken thread's own frames have nothing left to do but return
(K33). The rule is what lets a stop cut a wait short from any CPU
(K18), bounds what a sleeping thread pins to its wait record, and makes
one optimization safe by construction: an interrupt handler that ends a
wait may resume the thread straight to user mode through
`erx_wait_complete`, discarding its frames, as Fiasco's IRQ shortcut
does without this guarantee. That fast path is planned, not built: it
is adopted only when the deadline-to-resume benchmark (`tools/erx bench
timer`) and the device-line benchmark (`tools/erx bench irq`) show it
pays. The stopgap cannot take it, since Fiasco's IPC frames hold state
across the sleep, and its shortcut stays off
([design-stopgap.md](design-stopgap.md#transport)).

**Preemption points.** The kernel runs with interrupts masked except at
**preemption points**, which every long operation passes between bounded
parts: tearing down a deleted object, emptying a capability table,
copying or stopping a tree of spaces, range calls over many records,
backing a reserve, supplying a paged object, and copies through memory
windows, in parts of at most 64 pages. One more operation passes a preemption point without looking like
a long one: taking a helping lock, which may run a preempted holder in the
caller's place. At a preemption point pending interrupts are taken, and
the thread may be switched out for a more urgent one and later continue
where it was. Each part leaves every structure consistent.

**A started call runs to its end.**

*Stopping.* A thread whose space stops, or that a holder of `CONTROL`
stops, finishes the call it is in, a bounded part at a time, and dies or
stops only at its return to user mode, as Fiasco's dying thread does:
`Thread::prepare_kill` (`thread.cpp`) cancels the thread's waits and
diverts it on its way back to user mode. Only waits are cut short, since a
wait holds no work in progress: a thread waiting in a call (an IPC wait, a
umtx wait, a park, a quiesce wait for a paused space's threads, a
stopper's wait for a tree's record) is woken, and
it dies with its space or its call returns `ERX_EINTR` to a `CONTROL`
stop; a thread held at its return to user mode is in no call, and a stop
leaves its registers as they are ([Threads and
faults](#threads-and-faults)). So no operation is ever left
half done: a deletion's teardown, a release list, a table's emptying, a
walk that stops a tree and a copy of a space each complete in the thread
that started them, whatever happens to that thread meanwhile, and none
needs to be made again, which after a deletion would not even be
possible, since no lookup reaches a deleted object. A stopped space's
exit record therefore waits for the longest call its threads were making,
and every such call ends: each of its parts is bounded (K13), and their
number by the records it walks, which budgets paid for, the stopped
space's own or, for a deletion's or a release's teardown, those of the
spaces whose slots and mappings name the object. A thread of a stopped
space still inside a call is **finishing**. The rule holds for every
stop, whoever makes it: a parent's stop walk, the stop a release makes
and the stop a last thread's exit makes each post their tree's kills
from the call that stopped it, and the tree's finishing is charged to
the finishing threads' own paths.

*The kill.* `erx_space_stop` is one **walk** in
the stopper's call: in bounded parts it sets the stopped words of the
tree, sends its interrupts, and posts one **kill** to every thread of
the tree, which ends the thread's wait if it is in one; when the walk
is done, every thread of the tree is dead, finishing, or in user mode
on a CPU whose interrupt is on its way. From the kill on, the finishing
thread runs on its own CPU and its own stack, as any ready thread does,
at the **finishing level**, one level above the highest urgency, which
no user thread reaches, within its CPU's **finishing share**,
`ERX_FINISHING_TICKS` (4) of every `ERX_FINISHING_PERIOD` (8) ticks of
that CPU's clock, and outside every quota: no grant is drawn for it,
throttles it or places it, so a thread whose own group has no time left
finishes all the same, and nothing of its killer, neither grant nor
cpuset, is read
([design-scheduler.md](design-scheduler.md#pick-and-dispatch)).
A waiter for a lock it holds helps it as it helps any holder, and pays
for that help (**Locks** below). A kill names no group: the thread's finishing time is added,
for the accounting alone, to the `finishing_ns` of each group on its
own path, which the inspector reports apart from the groups' usage, so
a stopped domain's finishing shows on the stopped domain's groups; the
charge admits nothing and holds nothing back, and the thread holds that
path's groups as it always has, until its last switch
([design-scheduler.md](design-scheduler.md#charging-and-quota)). A kill
of a thread that is dying already changes nothing: its level and its
share were set by its first kill, its path at its creation, and none of
them depends on who kills it next. A kill of the thread its CPU is
running, its own exit, a stop of its own space or a kill that reaches
it there by a cross-CPU request, is a scheduling decision like any
other: the thread is charged up to the kill on its ordinary path, joins
the finishing level, and the CPU picks, so it runs on only while the
finishing share answers yes, as a killed thread made ready does
([design-scheduler.md](design-scheduler.md#pick-and-dispatch)).

*Unfinished first.* `STOPPED` says that no thread of the space will
return to user mode or be created, and nothing more; whether every kill
has been posted is kept in the order of the lists the walk reads. In a
space's `threads` list the threads with no kill posted come first: the
part that posts a thread's kill moves it to the end of the list, under
the space's lock, before the part's preemption point. In a space's list
of children the children whose walk is not done come first (**The two
walks** in [Creating spaces](#creating-spaces)). So a walk always
finds its remaining work at the front, and every stop walks: a stop of a
space that has stopped already is not refused and does not rely on the
walk that stopped it, whose thread may be throttled, descheduled or
never run again; it walks as a first stop does, posting the kills no
walk has posted yet and descending into every subtree no walk has
finished, and waits as a first stop does. Two walks of one tree may
post a kill to the same thread, which is a later kill of a dying
thread and changes nothing. Each finishing thread keeps its original call stack, locks
and completion path, and no second protocol replays or takes over its
effects. The destroy of a group kills its members the same way, each
charged to its own path, and so does the deletion or release of a
thread ([Closing and deleting](#closing-and-deleting)).

*Who owns unfinished work.* The finishing thread itself, which is a
fact about the thread's own record and not about any other thread: the
killer may be deleted, descheduled, throttled or killed in turn, and the
thread's own groups may be destroyed, and the finishing thread goes on
as before, since its service depends on its CPU's share alone, and it
holds every group of the path it charges, whose records take charges
until their last holder is gone
([design-scheduler.md](design-scheduler.md#ownership-and-lifetime)). A
ring of stops, two spaces each stopping the other or any longer one,
ends: every thread of the ring finishes at its own CPU's finishing
level, each death takes its own space's count down, and each record is
posted by its space's last death, which needs nothing of any stopper.
No grant keeps a finishing thread unfinished: a zero quota on its own
group or on any group above it leaves it running at the finishing
level, and its killer's grant is never read. What bounds its finishing is its CPU's share and
the parts its call has left, and what bounds the finishing of a tree is
the share on each CPU its threads are on and the records the tree's
budgets paid for; [design-scheduler.md](design-scheduler.md#pick-and-dispatch)
states the bound in periods.

*The stopper's wait.* After its walk the stopper waits for the tree's
exit record: it queues itself on the root space's `att_stoppers` and
reads the tree's word, with a full fence between, and sleeps in an
`ERX_WAIT_STOP` wait unless the word is `EXITED` already, holding
nothing (K33). The wait ends through `erx_wait_complete` in exactly
one of these ways: the death that takes the tree's last count to zero
publishes `EXITED` and wakes every stopper queued there, with `ERX_OK`;
a `CONTROL` stop of the stopper ends it with `ERX_EINTR`, after which a
stop of the same space waits again; a kill of the stopper, by its own
space's stop or its deletion, ends it with `ERX_EINTR` as well, which
nothing reads, since the stopper then dies at its return check. A stop
of the caller's own space, which is how a domain exits, is the last
case: the walk kills the stopper among its space's threads, and the
stopper dies at its boundary. Nothing of the stopped tree depends on
the stopper after its walk, so no death waits on a death.

*Charging.* A finishing thread's remaining work is charged, for the
accounting alone, to the thread's own path: the `finishing_ns` of every
group on it, kept apart from the groups' `used_ns` and `total_ns`, so
the inspector shows a stopped domain's finishing time on the stopped
domain's own groups, separately from the time its threads ran before the
stop, and attributes none of it to the party that stopped it. The
charge admits nothing and holds nothing back: a finishing thread draws
from no quota and no grant throttles it, so a stop completes however
little time the stopped group or the stopper's has left, and what a stop costs is
bounded on each CPU by the finishing share and in all by the records the
stopped tree's budgets paid for ([Security](#security)). The walk
itself, the emptying of a stopped space's table and its destroy are
kernel calls, charged to their callers as any call is and run in the
calls that ask for them; the reaper's steps run on idle time, one per
reap deadline on a busy CPU, or in the backing that needs the pages
([The reaper](#the-reaper)). A stop can take long, as long as the
longest call of the tree takes within the share, and its caller sleeps
until it returns, so a caller makes it from a thread that nothing else
waits on, and never from an executor, which the dispatch refuses with
`ERX_EWOULDBLOCK`
([design-scheduler.md](design-scheduler.md#executor-class-enforcement)).

No stretch with interrupts masked lasts longer than 20 microseconds under
HVF, a budget that the timing tests of [Verification and
testing](#verification-and-testing) check, so interrupt latency is bounded
by the longest part of any call, not by the longest call. An interrupt is
taken on the kernel stack of the thread it interrupts, on top of that
thread's deepest kernel frame, and handlers never nest, so the stack proof
adds one interrupt path to every thread's worst case ([Stack
proof](#stack-proof)).

**Locks.** There are two kinds, each declared next to a comment naming
what it protects:

* **Helping locks**, Fiasco's: a holder may pass preemption points while
  it holds one, and a thread that finds one held by a preempted thread
  runs the holder in its place, a bounded part at a time, until the lock
  is released, as Fiasco's `Switch_lock` helps towards release
  (`switch_lock.cpp`); a holder that is running elsewhere is in
  the middle of a bounded part and is waited for. The waiter's urgency and
  CPU time carry the holder through, so an inversion lasts as long as the
  holder needs the lock: a lock taken and released within one part costs a
  waiter at most the rest of that part, and an existence lock, which an
  operation holds across all its parts, costs a waiter the rest of that
  operation, whose parts the records it walks bound and budgets paid for,
  as a copy of a space makes a map into either space wait for the copy's
  end. Interrupt latency is a separate bound, the longest part (K13),
  since helping passes preemption points as any other work does. Each
  object has two, as in Fiasco (`kobject.cpp`): its **capability lock**,
  which guards its slot list, its capability count, its state word and
  every slot that names it, and its **existence lock**, which an operation
  holds while it changes the object across preemption points and which the
  object's destroy invalidates and then waits to be free. A space's lock
  is a helping lock too. Helping passes preemption points, on the helper's
  CPU, so it ends the helper's protection of every object it looked up
  without counting, as any preemption point does; which is why a fault
  takes its space's lock first and looks its mapping up only under it
  (**One hold**, [Virtual memory](#virtual-memory)).
  *A dying holder is helped as any other, as in Fiasco.* A waiter needs
  the lock whoever holds it, so the time is the waiter's own demand, and each
  part it runs is charged to its path, at its urgency, as all helping is.
  That fits the finishing rules because the finishing level and share bound
  what a CPU's pick chooses: a pick that chose the helper chose an ordinary
  thread, so a helped part takes nothing from any CPU's share and adds
  nothing to the holder's `finishing_ns`, and for the rest of its call the
  holder runs at the finishing level of its own CPU
  ([design-scheduler.md](design-scheduler.md#pick-and-dispatch)). The holder
  dies on its home CPU at its return check, whoever helped it, and it can
  start no new operation, so a waiter's help is bounded by the rest of the
  operation it holds the lock across.
* **Taking a capability lock.** `erx_object_lock_cap` takes it as
  Fiasco's `Kobject_mapdb::lock_obj` does (`kobject_mapdb.cpp`), without
  a counted reference: with interrupts masked it checks that the
  capability still names the object and tries the lock, after every help
  it looks the capability up again before it touches the object or its
  lock, and once it holds the lock it checks a last time, failing with
  `ERX_ESTALE` as soon as the capability no longer names the object. A
  slot names only an object whose teardown has not yet cleared that slot,
  and the record is freed only after a grace period that begins once the
  teardown has cleared them all, so what a fresh lookup finds is never
  freed memory, and an object whose capability lock a thread holds stays
  allocated however often that thread is preempted, since none of its
  slots can be cleared meanwhile. The generation in the capability value
  also catches a slot reused for another object at the same address,
  which `lock_obj` cannot tell apart. `erx_object_lock` takes the
  capability lock of an object the caller holds counted, as a teardown
  does, and `erx_object_unlock` releases either.
* **Taking an existence lock: borrowed, counted, locked.** A pointer from
  a lookup is borrowed: it is good until the thread's next preemption
  point. Taking an existence lock may help its holder, which passes one,
  so `erx_object_lock_existence` first turns the borrowed pointer into a
  counted reference, then takes the lock, and fails with `ERX_ESTALE`,
  dropping the reference, once the lock is invalid, as Fiasco's callers
  take a `Ref_ptr` before the lock (`task.cpp`);
  `erx_object_unlock_existence` releases both. Two existence locks are a
  handler's own, since the dispatch takes at most one: the handler takes them
  with `erx_object_lock_existence2`, which refuses two references to one
  object with `ERX_EINVAL` before any lock, counts both pointers before
  taking either lock, and takes them in address order. Such a handler is a thin
  function that takes the pair, calls its body once and releases the pair after
  the body returns, so no exit of the body can miss a release. An object already held counted
  by `erx_object_lock_counted_existence`. A record only its caller can
  reach, a construction record or an object not yet published, is
  locked by `erx_object_lock_fresh_existence`, which finds the lock
  free, which debug builds assert, and so never helps and never waits;
  `erx_object_unlock_fresh_existence` releases that lock alone, the
  caller's reference, which `erx_kalloc` gave it with the record, being
  the caller's to pass on or drop (**Construction** in [The
  reaper](#the-reaper)). So no borrowed pointer crosses a
  help: what crosses it is a counted reference, or, for a capability lock,
  a fresh lookup. An operation holds the existence lock of each object it
  changes across preemption points: a map, an image map and every range
  call hold their space's, as Fiasco's `fpage_map` holds the destination
  task's, and `erx_dma_map` and `erx_dma_unmap` hold their window's, each
  call declaring them in the ABI file and the generated dispatch taking
  them before its handler runs ([System-call
  dispatch](#system-call-dispatch)); a copy of a space takes both spaces'
  itself at its start, and each fresh child's construction's while it
  makes that child; a creation takes its construction record's from
  before its first admission until it has published or torn down what
  it made, and the new object's own across the inserts that publish it,
  and then holds the object counted, lock released, until the dispatch
  has installed its capability (**Construction** in [The
  reaper](#the-reaper)). A construction's lock and an unpublished
  object's are taken fresh by the creator alone and drained, never
  taken, by a destroy, so no thread ever waits to take one, and they
  stand outside the order's count and its address rule; a thread thus
  holds at most two existence locks taken by waiting, a copy's two, and
  beside them at most two taken fresh, the construction's and the
  object's of the child it is making. No thread waits, in the sense of
  a wait record, while it holds one, and none destroys an object whose
  existence lock it holds, since every destroy runs from a release list
  or in the deleting call, neither of which holds one, and a creator
  releases its object's lock, and every existence lock it holds beside
  the construction's, before it destroys an object it failed to
  publish.
* **Closing and draining.** An object's destroy begins by **closing**
  the object: it invalidates the existence lock with one atomic
  operation, and only the destroy whose invalidation found the lock valid
  goes on, so a deletion and a release that race destroy the object
  once. The invalid lock is the deletion's mark: from that store on,
  `erx_cap_lookup` refuses the object, every insert function refuses it,
  and no operation can take its existence lock. The destroy then
  **drains** the object: it waits until the existence lock is free,
  helping its holder if one still holds it, as Fiasco's `wait_free` does,
  so no operation that began before the close is still changing the
  object. Only then does the type's teardown run, on an object to which
  nothing attaches and on which nothing operates, which is the argument
  of Fiasco's `Task::destroy` (`task.cpp`).
* **Marking and attaching.** Every insert function of
  `kernel/core/attach.c` reads the object's state under the lock that
  guards its attachment field, or, for a thread's senders, on the
  thread's home CPU, which alone touches them (K14), and fails with
  `ERX_ESTALE` on a closed object, as a Fiasco gate refuses new senders
  once its existence lock is invalid (`ipc_gate.cpp`); an insert into a
  dying thread's queues fails with `ERX_EDEAD` whether or not the thread
  is closed, since the thread's own death drains its senders and nothing
  may queue after the drain, as on the stopgap
  ([design-stopgap.md](design-stopgap.md#ipc-gates-and-where-transfer-fits)); a space's creation
  of a child or a thread checks the same under the space's lock. An
  insert therefore either comes before the teardown's walk of that field,
  which finds its item, or after the close, and sees the mark. So nothing
  attaches after the close, and the teardown, a bounded part at a time,
  removes exactly what attached before it.
* **A mapping record attaches to two objects.** It joins its memory
  object's reverse map and the records of its space or DMA window, and its
  one insert function checks both objects' states, under the container's
  lock and then the object's, before the apply that adds it changes
  anything; a refused apply releases what its plan took, as a refused plan
  does. The operation that adds it holds the container's existence lock,
  so a map, an image map or a copy that is under way when its space or
  window is destroyed either adds its record before the close, and the
  destroy's teardown detaches it from its object, or meets the mark at the
  insert and adds nothing, and in both cases it has finished before that
  teardown begins ([Virtual memory](#virtual-memory)).
* **Spinlocks**, taken with interrupts masked and never held across a
  preemption point. Every one is a **ticket lock**: a taker draws the
  next ticket and holds the lock when the lock's serving number reaches
  it, so takers are served in the order they arrived, and a taker is
  behind at most `ncpus - 1` holders, each of which holds the lock for
  one bounded part with interrupts masked and so cannot be preempted
  while it holds it. The time a part spends taking a lock is therefore
  bounded in the execution time of the CPUs involved, by `ncpus - 1`
  critical sections of that lock, whatever the other CPUs do, and every
  part's bound (K13) counts that for each lock it takes. The inherited
  spinlock of the stopgap has no queue, so the C17 cores bring their own
  ([design-stopgap.md](design-stopgap.md#budgets-and-the-ownership-of-pages)).

No thread waits, in the sense of a wait record, while it holds a lock of
either kind: a call that must wait releases every lock first, and drops
every counted reference, since a wait holds nothing (K33). The order is
total and written in one place, `kernel/core/lock_order.h`:

1. existence locks taken by waiting, at most two at once, in address
   order (a copy of a space holds its two spaces'); a construction
   record's and its unpublished object's, which `erx_object_lock_fresh_existence`
   takes free and which no other thread can reach, are outside this
   count and this order, since nothing ever waits for them (**Taking an
   existence lock** above);
2. objects' capability locks, at most four at once, in address order (a
   pass holds those of the objects it passes; a teardown holds one);
3. a space's lock;
4. a capability table's lock, one at a time;
5. a memory object's lock;
6. budgets, a descendant before its ancestors: a charge that borrows
   holds its budget's chain of ancestors together, up to
   `ERX_BUDGET_DEPTH_MAX` locks, until its plan is applied; a budget's
   lock also covers its record caches, and arming or clearing a budget's
   watch takes the IRQ object's capability lock, at 2, before the
   budget's, holding no other capability lock ([Budgets](#budgets));
7. the released list, which a release takes alone and which a reaper
   step or the backing of a charge takes before the allocator's, so
   that what it finds on the list and on the free lists is one
   observation ([The reaper](#the-reaper));
8. the physical page allocator;
9. the grace tracker's lock, which guards the period counts and the set
   of CPUs a period waits for: `erx_grace_retire` takes it inside the
   released list's lock for a release, and alone for a put or a record
   free, which its CPU queues with interrupts masked and no lock; a
   CPU's quiescent-state report and a period's start take it alone. On
   the stopgap it is Fiasco's `Rcu_glbl::_lock`, rebuilt as a ticket
   lock
   ([design-stopgap.md](design-stopgap.md#budgets-and-the-ownership-of-pages)).

The other locks are leaves, taken holding none while held: a gate's
binding, a umtx bucket, a group's park lock and pool lock, the kernel
log, the entropy generator, the IOMMU's command queue, a
space's copy lock and the ASID allocator. They are
taken with no other lock held but existence locks, which an operation
holds across its parts and which come first in the order: `erx_dma_unmap`, holding its window's
existence lock, queues its invalidation and synchronisation under the
command queue's lock and releases that lock before it polls for the
completion, since no spinlock spans the preemption points between polls
([DMA and the IOMMU](#dma-and-the-iommu)). There are two exceptions: an
IRQ object's lock is a leaf that may take, inside it, the park lock of the
group it is bound to, so a trigger and an unbinding agree on where a
delivery goes; and a umtx bucket's lock may be taken inside the lock of
the memory object whose word it queues, so a wait compares its word,
queues itself and links the word's queue into the object's `att_words`
under that object's lock ([Umtx](#umtx)). The order has no level for
scheduler or request queues: a CPU's ready queues are written by that
CPU alone and its request queue is appended with release stores
(**Cross-CPU requests** below), so no lock guards them. The stopgap's
Fiasco does lock its queues and takes those locks inside leaves; that
level belongs to the fork's own lock-order check, recorded in
[design-stopgap-scheduling.md](design-stopgap-scheduling.md#concurrency-and-failure-behavior),
and not to this order. Debug builds check the order
on every acquisition, check that a fresh take finds its lock free, and
time every hold.

**Releases run unlocked.** When the last capability to an object goes,
`erx_cap_slot_clear` reports the release to its caller, which runs it
after it has dropped every lock, existence locks included, so no destroy
waits for an existence lock its own thread holds: releasing a space
closes and drains it, stops it, empties its table and detaches its
mapping records from their objects, which may release or destroy further
objects. Each release goes on the calling
thread's release list, and the call drains the list in a loop before it
returns, so a chain of releases is iterative, never recursive, and every
step of it is a bounded part. Fiasco does the same with its reap lists.

**Cross-CPU requests.** A thread's state belongs to its home CPU (K14).
Another CPU that wakes, stops or preempts it, or delivers a message or an
IRQ object to it, posts a request on the thread, lists the thread on its
home CPU's pending list and, when that CPU must act at once, sends it
`ERX_IPI_REQUEST`, an inter-processor interrupt, which carries no thread
pointer. A CPU drains its pending list at every kernel entry, at every
preemption point and before it idles, each thread's requests in order. A
thread is moved only by its home CPU, a running one from the idle context,
and since a request hangs on the thread, one posted during a move reaches
whichever CPU is home when it is drained. This is Fiasco's cross-CPU request
design, and it keeps each thread's queues free of locks; the rules are
written out, with their model, in
[design-scheduler.md](design-scheduler.md#concurrency).

**Object lifetime.** Objects die as in Fiasco (`kobject.cpp`): in two
phases separated by a read-copy-update (RCU) grace period. A capability
lookup takes no lock and no reference; the call runs in the RCU read side
until its next preemption point, wait or return to user mode, and an
object is freed only after a grace period that begins once its destroy has
finished, so no call ever uses a freed object. Read sides are tracked per
CPU, as in Fiasco, so a CPU that helps a lock holder through the holder's
preemption points ends its own read side there too: an object pointer from
a lookup is good only until the next preemption point of any kind, which
`erx_uref_t` makes checkable, and Fiasco's `lock_obj` handles the same way
by looking the capability up again after helping. A **grace period** ends
when every CPU has returned to user mode, idled or passed a preemption
point since it began. Every kernel path is bounded between preemption
points (K13), so a grace period lasts at most the longest bounded part,
and a CPU that idles or runs in user mode is quiescent at once: it
publishes a per-CPU quiescent count at each of those points, and the CPU
that waits for a period reads them and sends `ERX_IPI_REQUEST` only to a
CPU that has not moved since. Reference counts are kept only for a thread
that keeps an object across a preemption point, never across a wait
(K33): every taker of an existence lock takes one first, a range call
working through a space in parts among them; the groups of a thread's
path are the thread's from its creation until its last switch ([Objects
and capabilities](#objects-and-capabilities)); and a posted delivery holds
its object until it is taken or withdrawn. A
sender blocked on a gate, a waiter on a umtx word and a parked executor
hold none: each is linked on a list its owner's teardown empties, touches
that list on waking only while it is still on it, and reaches the object
again only through a fresh lookup. The stopgap's one exception is the
requester of a waited cross-CPU request, which holds its target across
the answer wait
([design-stopgap-scheduling.md](design-stopgap-scheduling.md#differences-from-erxoss-kernel)).
Pointers between objects are
attachments, which the target's teardown removes, where Fiasco counts
them ([L4 lineage](#l4-lineage)). Each put
waits on the list of the CPU that queued it, with the grace period it
waits for, and that CPU runs it once the period has ended, in idle or
at its reap deadline ([The reaper](#the-reaper)). An object's record
stays allocated until its put
and the last counted reference a thread holds have dropped, so a lookup
never reaches freed memory; the pages the object held are released by
its teardown, uncharged from then on, and are freed only after a grace
period of their own, so no walk reads a freed page either (K9)
([Budgets](#budgets)).

### Sequence-counted records

A record that one writer changes while readers on other CPUs, or in other
spaces, read it without taking a lock is a **sequence-counted record**:
a capability slot (**Reading a slot without a lock** in [Objects and
capabilities](#objects-and-capabilities)), a trace record ([Trace
ring](#trace-ring)), and any shared record that another subsystem's
design declares read the same way. Every such
record follows one rule, so a reader that races a writer has no data race
in C17's sense and keeps only a copy that is one state of the record:

* **Every field is atomic and generated.** Each field a reader may load
  while a writer stores it is `_Atomic`, the record's layout is declared
  once, in the ABI file for the kernel's records, and a generator emits
  the one load and the one store through which each field is reached; a
  check fails the build on any other access to such a field ([Chokepoint
  checks](#chokepoint-checks)).
* **The writer.** Writers are serialised, by the record's lock or because
  one thread owns the record. The writer stores an odd count with relaxed
  order, stores each field it changes with release order, and stores the
  next even count with release order.
* **The count's lifetime.** Every reusable record has a 64-bit count
  that increases without wrapping for the whole physical record's life,
  across reuse and recovery. Emptying a record or restarting its writer
  never resets its count. At the last even value, `UINT64_MAX - 1`, the
  next mutation publishes terminal odd `UINT64_MAX` and retires that
  record permanently instead of publishing another readable value. A
  retired record may finish its cleanup but is never reused; readers
  recognize the terminal value and report unavailable, stale or lost
  according to the record's protocol, rather than retrying forever.
  A subsystem that needs continued publication reserves a replacement
  through its ordinary admission path, and refuses or reports exhaustion
  if it cannot; it never silently starts the sequence over. A recovery
  that empties an abandoned nonterminal odd record advances it to the
  next even value after its serialized repair, not to zero. The ABI
  requires each record to declare this exhaustion and recovery behavior.
* **The reader.** The reader loads the count with acquire order, handles
  the terminal value as the record's declared exhaustion, and starts again
  while a nonterminal count is odd, loads each field with acquire order, loads
  the count again, and keeps its copy only if the count is unchanged.

A field the reader loads that a writer stored makes that writer's odd
count visible to the reader's second load, which cannot move before the
field loads, so a copy the reader keeps is one state of the record. This
is the sequence lock that H.-J. Boehm analyses for the C11 memory model
("Can Seqlocks Get Along with Programming Language Memory Models?", MSPC
2012). His other form, relaxed field accesses between a release fence
after the odd store and an acquire fence before the second load, is
equivalent in C17; erXos uses acquire and release accesses alone because
ThreadSanitizer models them directly, while its support for standalone
fences is partial. A writer preempted while its count is odd delays its
readers and never misleads them: each retries, or, where it must not
wait, as a trace reader must not, counts the record as lost. Every kind of
sequence-counted record has a host test under ThreadSanitizer in which
writers overwrite records continuously on other threads while readers
read them, which fails on a plain access to a field and on a kept copy
that matches no single state the writers wrote.
Reduced-width tests suspend a reader across every remaining publication,
clear, reuse and writer restart, including terminal retirement; an old
count can never become a fresh readable count again. Address reuse after
all possible readers have quiesced begins a new record lifetime, not a
reset of a record that an old reader can still reach.

### System-call dispatch

One generated function, `erx_dispatch`, serves every kernel call: the
architecture's system-call trap, with the call number and up to six
arguments in the registers the binding assigns
([design-arch-aarch64.md](design-arch-aarch64.md#system-call-trap)).
Each call in the ABI file declares its arguments with their types, the
rights each capability needs, its results, the budget that pays for what
it allocates, whether it may wait, its bound per part, and, for a call
that may wait, whether an executor may make it
([The ABI file](#the-abi-file)). For one call:

1. **Number.** An unknown number returns `ERX_ENOTSUP`.
2. **Executor rule.** A call that may wait and is marked `executor:
   refuse` returns `ERX_EWOULDBLOCK` when the caller is an executor
   ([design-scheduler.md](design-scheduler.md#executor-class-enforcement)).
3. **Arguments.** Each is decoded by its declared type, and the first
   failure returns its status with no effect. Every argument comes from one
   of three places, and the ABI file's grammar has no fourth: a register,
   a field of the caller's UTCB, or a memory window ([Arguments and
   results](#arguments-and-results)). The decoder orders its work so that
   no uncounted lookup is followed by a preemption point before the
   handler runs: first every argument that is not a capability, in
   declaration order, then the capability whose existence lock the dispatch
   holds, if any, then every other capability, in declaration order. Taking an
   existence lock is a preemption point, which ends every uncounted
   reference a lookup returned (K1), so with the plain lookups last the
   references a handler receives are fresh; and since a plain lookup takes
   no reference, and a failure releases the existence lock taken before
   it, a failure at any argument leaves nothing to undo. The generator
   emits this order for every call, whatever its declaration order:
   * a message tag is decoded from its register, and the typed items and
     buffer descriptor it implies are loaded once from the caller's UTCB
     into kernel memory and checked there: counts within their limits,
     reserved bits zero ([Messages, gates and IRQ
     objects](#messages-gates-and-irq-objects));
   * an argument the ABI file places in the UTCB, in a layout the ABI file
     declares, is loaded field by field into kernel memory through
     `erx_shared_load_*`, once, and decoded there, so user mode rewriting
     the UTCB meanwhile changes nothing the call decides on;
   * a page-aligned user address becomes an `erx_uvpn_t`, and a size in
     whole pages an `erx_npages_t`;
   * an integer is checked against its declared range, alignment and flag
     mask, whose undefined bits must be zero;
   * an argument the ABI file marks `exists` is looked up next and its
     existence lock taken with `erx_object_lock_existence`, which may help
     its holder, so its object reaches the handler counted and locked, and
     the completion releases it. The dispatch takes at most one such lock,
     and the ABI schema refuses a call that declares more; a call that
     needs two, as `erx_space_copy` does, declares neither, and its handler
     takes both as its first act (**Copying a space** in [Copy-on-write
     children and copies of
     spaces](#copy-on-write-children-and-copies-of-spaces));
   * last, a capability goes through `erx_cap_lookup` in the caller's
     table with the declared type and rights, and the `erx_uref_t` it
     returns stays valid until the call's first preemption point or wait,
     taking a helping lock included; a handler that needs the object past
     one takes a counted reference with `erx_object_ref` before it, takes
     its existence lock with `erx_object_lock_existence`, which counts it
     first, or takes its capability lock with `erx_object_lock_cap`, which
     looks it up again after every help ([Execution model and
     locking](#execution-model-and-locking)); a window's capability is
     looked up so, with the right its direction needs, and its offset and
     length are then checked against the object's size with checked
     arithmetic and the length against the declared maximum, which the
     generator keeps at or below `ERX_COPY_MAX`;
     `ERX_CAP_SELF` names the caller's own space with `MAP`, `THREADS`,
     `CAPS` and `STOP`, and `ERX_CAP_SELF_THREAD` its own thread with
     `CONFIGURE`, as the ABI file declares, through this same lookup
     (**Reserved values** in [Objects and
     capabilities](#objects-and-capabilities)).

   The decoder, `erx_sys_decode_shape`, does the first four kinds of work
   and touches no object. The capabilities are the admission core's, a
   pure state machine (`kernel/core/admit.c`) over the call's generated
   **admission plan**, which lists its capability arguments in the order
   above with each one's type and required rights: the core returns one
   action at a time (a lookup, the existence lock, the handler's run, its
   release, the end) and the dispatch performs it and reports its status.
   So the order of lookups and the lock, and the release of the lock the
   dispatch holds on every path, failure or not, are decided in one place that host
   tests drive through every failure point. The dispatch reports a
   window's checks as its lookup's status and the installation of step 5
   as the handler's, and starts a new admission of the same shape for a
   retry.
4. **Handler.** `erx_sys_<name>` receives the decoded arguments and the
   calling thread, does its work in bounded parts on the thread's own
   stack, and returns a status and its results. A call that must wait
   returns with the wait's inputs stored in the thread's wait record
   and every lock and counted reference returned, and the dispatch
   takes it to the wait funnel after step 6, so the sleep holds nothing
   (K33, [A wait holds nothing](#execution-model-and-locking)). The
   generator emits the handler's prototype, so a missing handler fails
   the link.
5. **Installation.** For a call that creates an object, the handler's
   result is the object, held counted, and the dispatch owns that
   reference from here: it installs the capability in the caller's
   table under the object's capability lock, and destroys an object it
   installs no capability to (**Construction** in [The
   reaper](#the-reaper)).
6. **Completion.** The counted references the handler took, and the
   installation's, drop, the thread's release list is drained
   ([Execution model and locking](#execution-model-and-locking)),
   and the status and up to two results go into the caller's result
   registers; a call with more results has written them into the
   caller's UTCB or into the window it named, which cannot fault.

Any other system's system-call trap, which the binding tells apart from
erXos's, stops the thread with a fault of kind `ERX_FAULT_FOREIGN_TRAP`,
which catches a binary built for another system at its first call.

### Threads and faults

**Creating and starting.**
`erx_thread_create(budget, space, group, class)` makes a stopped thread
with the registers the caller's UTCB holds, in the ABI file's layout of a
thread's general register set, its kernel stack and its kernel-user page,
all charged to `budget` and backed before the call returns;
`erx_thread_start` makes it ready on a CPU
of its effective cpuset. Both refuse a stopped space with `ERX_EDEAD`. A
holder of `CONTROL` can stop a thread, read and write its registers while
it is stopped, and start it again. `erx_thread_stop` posts the stop
through a request to the thread's home CPU and returns once that CPU has
applied it, without waiting for the thread to reach the stop, as Fiasco's
`Thread::kill` waits for its request to a thread on another CPU but not
for the thread to die (`thread.cpp`, `context.cpp`); that wait is a
bounded spin with no wait record, so the call never waits. `erx_thread_read(thread, set)` and `erx_thread_write(thread,
set)` move one register set through the caller's UTCB, each set a layout
of the architecture's ABI file that fits the UTCB's message registers,
which the generator checks, so a register file larger than the UTCB is
split into numbered sets; both refuse a thread that has not stopped yet
with `ERX_EBUSY`. The stop takes effect at the
thread's next return to user mode (**The return to user mode** below), and
nothing is lost on the way: a call's wait the thread is in ends with
`ERX_EINTR`; a call that is working finishes first; a thread held at the
boundary by a pause or a copy (**Pausing a space** below) stops there with
the outcome of the call it finished already in its registers.

**Faults.** The architecture layer decodes every synchronous exception
from user mode into its class, cause, address and access, and
`erx_fault_classify` maps it to one of three results, by an exhaustive
`switch` on the class with a default arm (K12):

* **a kernel call** (erXos's system-call trap), to the dispatch;
* **a memory fault**: a translation fault or a permission fault at a user
  address, which the fault decision of [Virtual memory](#virtual-memory)
  resolves over the mapping that covers the address, whichever of the two
  the CPU reported;
* **a fault record** for everything else: alignment faults, undefined
  instructions (trapped vector extensions included), breakpoints, another
  system's system-call trap, and an asynchronous error attributed to the
  thread.

```c
typedef struct erx_fault {
	uint32_t	kind;		/* ERX_FAULT_*: memory, deleted, undefined,
					 * alignment, breakpoint, foreign_trap,
					 * async_error, budget, exit */
	uint32_t	cause;		/* the cause as the CPU reported it, in the
					 * binding's encoding */
	uint64_t	addr;		/* the faulting address, where meaningful */
	uint64_t	pc;		/* the faulting instruction's address */
	uint64_t	thread;		/* object id of the thread, or of the stopper */
	uint64_t	space;		/* object id of its space */
	int64_t		status;		/* for exit: the status of the first stop */
} erx_fault_t;
```

A fault record stops the thread, which then waits as a sender at the
space's **fault gate**: the thread bound to the gate receives the record as
a message whose words are the record and whose label is the space's fault
label. The gate and the label are arguments of `erx_space_create`, its
only source, and no call changes them, so no code in the space can
redirect its records, and an armed thread's faults go the same way, since
the subset of the vCPU interface has no flag that diverts a fault (K28,
[vCPU upcalls](#vcpu-upcalls)). A thread has at most one record waiting,
so what waits at a fault gate is bounded by the threads of the spaces it
serves, and by those spaces for exit records. The fault gate's server
decides: resume the thread with `erx_thread_start` after repairing what it
can, which withdraws a record not yet received, or stop the space. The
space is on its fault gate's list of the spaces it serves; once the gate
is destroyed, released or deleted, its teardown clears the space's fault
gate, a record sent after that is dropped and counted in the space's
inspection, and the thread stays stopped. A space's deletion withdraws
its exit record ([Creating spaces](#creating-spaces)), so a space's
record waits for its gate's server only while the space lives. The system domain's `liberx` is
the server of every domain's fault gate
([design-system.md](design-system.md#ending-a-domain)), and a sub-space's
creator names its own ([Creating spaces](#creating-spaces)). The first
space, the root task's, which the kernel builds at boot, has no fault
gate: it holds the root authority and nothing can recover it, so a fault
in it ends the machine, after a crash record ([The root
task](#the-root-task)).

**The return to user mode.** Every path back to a thread's code, at the
end of a call, after a wake or a start, after an interrupt taken in user
mode, and from `erx_vcpu_resume`, passes one function, `erx_return_check`
([Chokepoint checks](#chokepoint-checks)). It is a pure decision over
what it loads once: its space's `stopped` word and hold count, the
kill or `CONTROL` stop posted to the thread, and the thread's upcall
state. The first row that holds decides:

| Order | When | The thread |
| --- | --- | --- |
| 1 | its space has stopped, or the thread is deleted or released | dies: it runs its own part of the teardown (**Deleting a thread** in [Closing and deleting](#closing-and-deleting)) and never returns to user mode |
| 2 | a holder of `CONTROL` has stopped it | stops, its registers kept, until `erx_thread_start` |
| 3 | its space is held: `holds` is not zero | waits in an `ERX_WAIT_PAUSED` wait, and decides again when the last hold goes |
| 4 | `erx_vcpu_step` finds a delivery it can take: the thread is armed, events are enabled and a delivery is queued | enters the upcall ([vCPU upcalls](#vcpu-upcalls)) |
| 5 | otherwise | resumes its frame |

A thread waiting in `ERX_WAIT_PAUSED` is woken by its space's stop, by
its own deletion or release and by a `CONTROL` stop, as well as by the
last release of a hold, and decides again. So a hold never delays a
death or a stop: a thread deleted while its space is paused for job
control runs its own part at once, and its senders, its caller and its
executor slot do not wait for the resume. Rows 1 and 2 need no user
mode, so they come before the hold, and the upcall, which runs user
code, comes after it. The space core's exhaustive model explores the
decision over stops, kills, `CONTROL` stops, holds and deliveries in
every order (K30).

**Ending a space.** `erx_space_stop(space, status)`, with `STOP`, stops
the space and every space below it ([Creating spaces](#creating-spaces)).
Stopping one space sets its `stopped` word, records the first stop's
status and the object id of the thread that made it, and interrupts every
CPU whose current thread belongs to the space: each CPU publishes the
space of the thread it runs before it reads the word at a return to user
mode, and the stopper reads those after it sets the word, each with a full
fence, so a thread in user mode is either seen and interrupted or sees the
word itself. A space stops once; a later stop changes nothing. Whether a
thread may run is then decided at its return to user mode, by row 1 of
`erx_return_check`; a thread inside a call finishes it first ([Execution
model and locking](#execution-model-and-locking)). Each space counts its
**active** threads, those running or preempted inside a call: a thread
enters the count when it is switched in from user mode or wakes, before
anything reads `stopped`, and leaves it when it is switched out from user
mode, sleeps in a wait or dies. Every return to user mode reads `stopped`,
and a thread of a stopped space dies there; the interrupt brings every
thread running in user mode to that check at once. The CPU that takes the
count to zero while `stopped` is set, or the stopper itself if it finds
the count at zero, posts the space's exit record, at most once. A thread
that wakes after the stop reads `stopped` before it can return to user
mode, so once the count reaches zero no thread of the space runs or can
run again, and no list of threads had to be complete for that to hold.
`erx_thread_create` and `erx_thread_start` refuse a stopped space with
`ERX_EDEAD`; waiting threads are woken and die the same way, which the
stop call does by walking the space's `threads` list in bounded parts
and posting a kill to each; the call returns `ERX_OK` only when no
thread of the tree is active or waiting, so when `erx_space_stop`
returns `ERX_OK`, no thread of the tree runs or can run again, and
every exit record of the tree has been posted ([Execution model and
locking](#execution-model-and-locking)). The call can therefore take
long: the tree's threads finish their calls at the finishing level,
each on its own CPU within that CPU's finishing share, and the stopper
sleeps until the tree's last record is posted, so its caller makes it from a thread that nothing
else waits on, never from one that serves others or holds what others
wait for, and never from an executor, which the dispatch refuses with
`ERX_EWOULDBLOCK`. Once its walk has set every `stopped` word, sent
every interrupt and posted every kill, the stopper waits in an `ERX_WAIT_STOP`
wait, holding nothing (K33), until it reads `EXITED` (**The stopper's
wait** under [Execution model and locking](#execution-model-and-locking));
its own kill ends that wait: a stopper whose own space is stopped while
it waits, by another space or by the one it is stopping, wakes, never
returns to user mode, and dies at its own return check. Nothing of its
target depends on it: the target's record is posted by the target's
last death, which needs no stopper, and what the target's threads have
left to finish runs at the finishing level within each CPU's share,
whether the stopper lives or not, charged to the threads' own paths.
So two spaces stopping each other, or any ring of stops, end:
each stopper's wait ends at its own kill, each thread finishes within
its CPU's share, each death takes its own space's count down, and no
death waits on a death (**Who owns unfinished work** under [Execution
model and locking](#execution-model-and-locking)). A stop of a space
that has stopped already changes no word and posts no record; it walks
as a first stop does, posting the kills no earlier walk has posted, and
waits as a first stop does (**Unfinished first**, under [Execution model
and locking](#execution-model-and-locking)). A thread joins that list at
its creation, under the space's lock, which also
checks that the space has neither stopped nor been closed, moves to its
end when its kill is posted, and leaves it when it dies, so once the
space has stopped the list only shrinks, the threads still to be killed
are at its front, and it holds every thread that may still be waiting. A space whose last thread
exits with `erx_thread_exit` stops as if that thread had called
`erx_space_stop` with status 0, as a POSIX process does when its last
thread exits, and a space whose last thread ends any other way, by a
deletion or a release of the thread, stops with the kernel's status
`ERX_EXIT_NOTHREAD`: the thread count drops in one place, the thread's
teardown, which makes that decision, so a space never lingers with no
thread and no record, whatever ended its threads. `ERX_CAP_SELF` always
carries `STOP`, so a runtime ends its own domain the same way, which is
how a domain exits. The exit record carries the status and the stopper's
object id in the fault record's `thread` field, or `ERX_EXIT_PARENT` and
the parent's stopper for a space stopped because its parent stopped.
`ERX_EXIT_PARENT`, `ERX_EXIT_RELEASED` and `ERX_EXIT_NOTHREAD` are the
kernel's own: `erx_space_stop` refuses each as a status with `ERX_EINVAL`,
so a record that carries one was written by the kernel and a creator can
trust what it says. The record lives in the space's own record and waits
at the fault gate as the space's one sender, so a gate's queue stays
bounded, and a creator learns in one place of every end of its spaces
that it, or another party, does not delete first.
It queues as an IRQ delivery does, as a sender of `ERX_URGENCY_MAX`, so
the records at one gate arrive in the order they were posted, a tree's
children before their parent. A dropped record counts as posted for its parent's.

**A deletion takes the record with it.** The space's `exit_bits` word has
two bits, each set once by one atomic fetch-or: the post sets one
(`erx_space_exit_post`) and the critical section that begins the deletion
the other (`erx_delete_walk_begin` or `erx_delete_walk_step`), so of the two
the second sees the first. A post that finds the deletion begun drops the
record and counts it. A record that goes on waits in one place, at one
thread's queue, which only that thread's home CPU touches, or on its gate's
`att_blocked`, and may move: a dying receiver's drain moves its queued
records to the gate's next binding or holds them at the gate, and a gate
bound again leaves what the old thread has queued where it is. So the gate's
lock, a leaf, is what orders a record with its withdrawal. Every placement, the
post's and each move, is made under that lock: it asks
`erx_space_exit_waits`, drops and counts the record when the deletion has
begun, and otherwise records the place in `exit_at`, sending any queueing
request before it drops the lock. A deletion that finds the record posted
withdraws it under the same lock: it takes it off `att_blocked` itself, or
sends a request to the home CPU of the thread `exit_at` names, after any
queueing request, which removes the record if it is still there and counts
it. A request refused because that thread is past its dead mark needs no
more, since its drain's placement finds the deletion begun. The withdrawal
is an unwaited request on a node of its own in the space's record, holding a
reference on the space until it is applied, as every unwaited request holds
its object, so it never reads a freed record. A gate destroyed with a record
on its list drops it as it does any delivery. The count is the
`exits_dropped` of the space's fault gate, or, when the gate is gone, the
space's own count of dropped records in its inspection, as for any later
record. So a space's record waits for its gate's server only while the space
lives. A destroy does not wait for the exit record, so a space destroyed or
released while it runs is deleted before its record could be received, and
such a record is seldom more than a count: a creator that wants a record
stops the space and receives it before it deletes, as the system domain and
a session do, and one that loses a record to a deletion sees the gate's count
and `ERX_ESTALE` on its capability.

**Pausing a space.** A space can be **held**: its threads go on running
kernel code, but none returns to user mode.

* **The calls and the holds.** `erx_space_pause(space)`, with `STOP`,
  takes a **hold** on the space and returns its **ticket**, a 64-bit
  value that names that hold and never another: its low six bits are
  the **slot** the hold occupies, one of `ERX_SPACE_HOLDS` (64), and
  the rest is the space's count of pauses so far, which every pause
  advances and which does not wrap within a boot. The space's `holds`
  word has one bit per slot, set while a hold occupies it, and
  `hold_ticket[]` the ticket of the hold in each occupied slot: the
  pause takes the lowest clear bit and writes the ticket beside it, and
  `erx_space_resume(space, ticket)` clears the bit of the slot the
  ticket names when that slot holds that ticket, both under the space's
  lock. A hold is **held** while its slot's bit is set and the slot's
  ticket is its own, which is what a quiesce at its queueing and a copy
  between its parts read, under the same lock: a hold resumed is held
  no longer, whether its slot is free or a later pause has taken it,
  since the slot's ticket is then the later hold's. So a ticket that
  was resumed names nothing afterwards, and the case a slot index alone
  would raise, a copy or a quiesce going on under a hold that replaced
  the one it was asked under, cannot arise. A pause that finds every
  bit set fails with `ERX_ELIMIT`; a resume, a quiesce or a copy that
  names a ticket not held, never issued, resumed already or of a slot
  a later hold occupies, fails with `ERX_EINVAL`; and both refuse the
  caller's own space with `ERX_EINVAL`, so a paused space cannot lift
  its own pause. A hold names what is done under it: a quiesce and a copy run under one
  hold, and resuming that hold ends them, whatever other holds remain
  (**Quiescing** below). A copy of the space for `fork` runs under a
  hold that its caller, the session, takes and resumes around the copy,
  as it takes one for each cause it records (**Copying a space**,
  [Copy-on-write children and copies of
  spaces](#copy-on-write-children-and-copies-of-spaces)).
* **Quiescing.** `erx_space_quiesce(space, ticket)`, with `STOP`, waits
  under the hold the ticket names until the space is **quiesced**: no
  thread of it runs, or is preempted inside a call, since it was first
  held. The call refuses the caller's own space, and a ticket not held,
  with `ERX_EINVAL`. It queues itself on the space's `att_quiescers`,
  its ticket in its wait record, and then
  reads the active count (K18), with a full fence between, and the CPU
  that takes the count to zero while the space is paused sets the
  space's `quiesced` mark and wakes every waiter queued there, as it
  posts a stopped space's exit record, so a count already at zero is
  seen, a later one is not missed, and two callers quiescing one space
  are both woken; a pause that finds the count at zero once its
  interrupts are acknowledged sets the mark itself. The wait holds
  nothing (K33): the thread queues itself, releases every lock and
  reference, and sleeps in an `ERX_WAIT_QUIESCE` wait, which ends in
  exactly one of these ways, each through `erx_wait_complete`: the mark
  is set, with `ERX_OK`; the hold it waits under is resumed, with
  `ERX_EBUSY`, since what was asked under that hold is wanted no
  longer, whatever other holds remain; the space stops or is
  closed, with `ERX_EDEAD`, the stop waking the quiescers as it wakes
  the space's waiting threads and the teardown's walk of
  `att_quiescers` waking any left, as it wakes a gate's senders; a
  `CONTROL` stop of the waiter, with `ERX_EINTR`; or the waiter's own
  death, which cuts the wait short as it cuts any wait. So the wait ends
  whenever its condition holds or can no longer hold, and whoever holds
  `STOP` on the space ends it at will by resuming its hold: giving up a
  `fork` while its quiesce waits, because a thread of the source cannot
  finish its call for want of its group's time, is the resume of the
  copy's hold, which the request's owner makes and which leaves every
  other hold on the source, a job's among them, as it was
  ([design-programs.md](design-programs.md#the-second-tier)). The mark
  holds until the resume that
  lifts the last hold clears it, because a thread of a paused space that
  wakes from a wait does nothing but complete that wait, which writes
  its registers and UTCB (K33), and go to the boundary; the mark is read
  by `erx_space_copy`, which refuses a space without it (**Copying a
  space**).
* **Where holds act.** Only `erx_return_check` acts on the holds, in row 3
  of its table, reading whether any is held; the space core's pause and
  resume functions alone change the `holds` word, the pause count and
  the slots' tickets, and a quiesce and a copy read one slot of them,
  their own hold's bit and ticket. A thread of a held space waits there, in an `ERX_WAIT_PAUSED`
  wait, and continues when the last hold goes, whose release wakes the
  threads waiting there. A hold interrupts every CPU whose current thread
  belongs to the space, as a stop does, and `erx_space_pause` returns only
  once each of those CPUs has entered the kernel since the hold was
  published, which it reads from the CPU's count of kernel entries: by
  then no thread of the space runs in user mode, and none can go back
  there while the hold lasts, since each reads the holds at its return.
  The order makes an earlier entry useless as an acknowledgement. The
  pause publishes the hold and issues a full fence, and only then reads
  each CPU's published current space and its count of kernel entries, the
  **baseline**, and interrupts each CPU whose current thread belongs to
  the space; a CPU, for its part, counts each kernel entry and publishes
  each switch with a full fence after it, before it next reads the holds
  at a return to user mode. With a fence on each side, the pause's reads
  and a CPU's update never miss each other: a CPU that the pause did not
  find running a thread of the space reads the hold before it returns to
  user mode in one, and of a CPU that it did find running one, the pause
  accepts only an entry that its baseline did not count, which reads the
  hold before it returns, never an entry the baseline counted, which may
  have read the holds before this one existed. That wait is bounded by the
  longest stretch with interrupts masked (K13), and nothing any thread
  does can prolong it.
* **Why a held space drains.** Nothing else looks at the holds: a wake or
  a start makes a thread of a held space ready as usual, a thread
  preempted inside a call runs to the end of it, and a helper runs a lock
  holder of a held space as it runs any other, each then reaching the
  boundary and waiting there. So a hold never keeps a thread from
  finishing work it started or from releasing a lock another thread
  needs, a held space's active count (K18) falls to zero once its threads
  have finished their calls, and the result of a thread's last call is in
  its registers while it waits.
* **Composition and scope.** Holds compose: each is a bit of its own, a
  session pauses a program's sub-space once for each cause it records,
  a copy of it among them, and resumes each by its ticket
  ([design-programs.md](design-programs.md#a-program-is-a-port)), so none
  lifts another's, and resuming one ends only what ran under it. A
  death or a stop comes before a hold (rows 1 and 2): a stop, which is
  final, still ends a held space, its waiting threads dying. A hold
  applies to the space it names alone, so a parent's pause and a parent's
  stop differ: the stop ends every space below the parent (K27), and the
  pause holds the parent only, its children running on unless held
  themselves. Which spaces a job's pause holds is decided by the session's
  job table, the session pausing each sub-space of each program in the
  job ([design-programs.md](design-programs.md#a-program-is-a-port)),
  never by the tree of spaces, since a program's children may belong to
  other jobs. Fiasco has no pause of a whole task: a task's manager acts
  on its threads one at a time ([L4 lineage](#l4-lineage)).

**Four states.** A space's threads are kept from acting at four depths,
each a fact the kernel establishes rather than assumes, and each caller
waits for exactly the one it needs:

| State | What it guarantees | Who waits for it | What the wait depends on |
| --- | --- | --- | --- |
| user execution prohibited | no thread of the space runs in user mode, and none can go back there | `erx_space_pause`, before it returns | the interrupts the hold sent being taken, within the longest stretch with interrupts masked |
| kernel mutation quiesced | the first state, and the space's active count (K18) has reached zero since the pause began: none of its threads runs, or is preempted inside a call, and the `quiesced` mark says so | `erx_space_quiesce`, before it returns; `erx_space_copy` requires the mark and waits for nothing | the space's own threads finishing the bounded parts of calls they started, on their own groups' time or a helper's |
| outside writes resolved | nothing another party does changes what a copy reads, except a whole item at a time, and memory the program gave another party or a device, which may change within a page, as it may under the program's own threads | no one: it holds by construction, below | nothing |
| terminating | the space has stopped, which is final: its threads die at their return to user mode, a death coming before any hold, and their waits are cut short | its exit record, which also waits for its children's (K18, K27) | the space's own threads finishing their calls, at the finishing level, charged to their own paths' `finishing_ns` |

**Outside writes.** Private memory, which a copy copies, has no
capability, so no other party, no device and no call made for another
party writes it (K5). What a copy shares rather than copies, a shared
object, others may go on writing, as another
process may write a `MAP_SHARED` mapping across a POSIX `fork`, and an
immutable object nobody writes. A copy-on-write child's pages, which a
copy copies, change only through a capability the program gave away, to
another party or a device's window, and then change under the copy as they
would under the program's own threads. A slot or a mapping record changes
only under the locks a copy takes to read it.

**Blocked calls.** A hold waits for no peer, because every thread of a
held space is in one of these states, each either stable or ending by
itself:

| A thread of the held space that is | Active | Its state ends at | What it can still change |
| --- | --- | --- | --- |
| running in user mode | yes | the hold's interrupt, which sends it to the boundary | nothing once it is there |
| running or preempted inside a call, or run by a helper | yes | the end of the call, a bounded part at a time (K13) | what its call changes, before the space is quiescent |
| asleep in an IPC wait, a umtx wait, a park or a quiesce wait on another space | no | its message, reply, wake or delivery; its deadline; its peer's death; the space's stop; its own death; a `CONTROL` stop, with `ERX_EINTR`; for a quiesce wait, the other space's mark, with `ERX_OK`, a resume of the hold it waits under, with `ERX_EBUSY`, or that space's stop or close, with `ERX_EDEAD` | its registers, its kernel-user page and the slots its receive reserved, which a sender fills: no call that may wait takes a memory window ([The ABI file](#the-abi-file)), a quiesce changes nothing of the space it waits on, and a copy copies a reserved slot as free |
| waiting at the boundary | no | the last hold's release, the space's stop, its own death or a `CONTROL` stop | nothing |

So user execution stops once the interrupts are taken, quiescence waits
only for kernel work the space's own threads started, and neither waits
for a reply or anyone outside the space. A quiesce that must be
given up all the same, because the source's groups have no time left to
finish that work, is ended by the resume that lifts the source's last
hold, which wakes it with `ERX_EBUSY`, or by the source's stop, with
`ERX_EDEAD` (**Pausing a space** above); a copy under way ends the same
way at its next part, or at a stop of its target (**Copying a space**,
[Copy-on-write children and copies of spaces](#copy-on-write-children-and-copies-of-spaces)).

**Emptying a stopped space's table.** `erx_space_clear_caps(space)`, with
`CAPS`, refuses a space that is not stopped with `ERX_EINVAL`, and closes
the slots of the space's own table, through `erx_cap_slot_clear` in
bounded parts until none is left, after a stop walk of the space that
kills whatever an earlier walk left unkilled below it (K27); once it
starts on the table, the table accepts nothing more. The space stays on
its parent's list, and so does every space below it on theirs: only a
deletion takes a space off a list. Everything the table held loses that
holder: an object the space created and kept to itself is released, and
what it passed to others stays with them while the budget that pays for
it lives. The call holds the space's existence lock across its parts, as
every range call does, and what its clears release runs from the thread's
release list after it has dropped that lock, so two emptyings of one table
never overlap: a second call and a deletion's drain wait for it, helping
it. A creator that wants a stopped tree gone
deletes its root, whose walk deletes the tree (**Who owns a deletion**). A
domain's end needs no emptying: the system domain destroys the domain's
own budget, which deletes the domain's space, every space below it and
everything else charged there at once, so nothing a dead domain charged
to its own budget survives and no space of it is kept for inspection;
its fault record and the dump in its crash area carry what inspection
needs ([design-system.md](design-system.md#ending-a-domain)). The
threads' records, the space's mappings and the table's pages stay until
the space's last capability goes or its parent is deleted; the space's
destroy then detaches its mappings from their objects in the call that
removed that capability or deleted that parent
(**Lifetime** in [Creating spaces](#creating-spaces)). An executor of a
stopped space counts as gone for its group from the stop on, so a group
whose executors' space stopped takes new executors and their deliveries
at once ([design-scheduler.md](design-scheduler.md#park-and-wake)).

### Creating spaces

Any holder of a budget that carries `SPACES` creates spaces, as any holder
of a factory creates tasks in Fiasco:

```c
erx_status_t	erx_space_create(erx_cap_t budget,	/* ALLOC, SPACES: pays for it */
		    erx_cap_t parent,			/* CAPS: ERX_CAP_SELF or a space below */
		    erx_cap_t fault,			/* SERVE: receives its records */
		    uint64_t label,			/* on each of its records */
		    uint32_t flags,			/* ERX_SPACE_JIT */
		    uint32_t cap_limit,			/* at most ERX_CAPS_MAX */
		    erx_cap_t *space);			/* out: the space, every right */
```

The new space starts empty: no mapping, no thread, an empty table, a fresh
ASID drawn when it first runs, its own pointer-signing keys and a random
placement base. Its record, its root translation table and its capability
table's pages are charged to `budget` and backed at the creation, the
tables through its reserve. The creator then builds it with the calls that serve its own
space: it maps objects it holds into it beneath their ceilings (`MAP`),
creates its threads in groups it holds (`THREADS`), gives it capabilities
with `erx_cap_pass` from its own table (`CAPS`), and starts the threads. A space it creates
runs only code its creator could map with execute, and allows JIT objects
(`ERX_SPACE_JIT`) only when `budget` carries `CODE`, as the system
domain's does, or when the creator's own space allows them, so the right
to make code follows from the image (K8). The system domain creates every
domain this way ([design-system.md](design-system.md#creating-a-domain));
a domain whose budget carries `SPACES` creates **sub-spaces**, which run
code its creator chooses, such as code of unknown provenance, holding only
the capabilities they were handed
([design-system.md](design-system.md#sub-spaces)).

**Every space has a parent.** Every space but the first names its parent
at creation, the creator's own space or a space below it, which the
creation checks by walking up the named parent's fixed chain of parents,
at most `ERX_SPACE_DEPTH_MAX` steps, to the caller's space; nothing
changes the parent afterwards (K27). A space stops when its parent stops,
with status `ERX_EXIT_PARENT`, so a whole tree of spaces stops with its
root: `erx_space_stop` stops the space it names and walks the spaces below
it with `erx_space_stop_tree`. A space's tree is at most
`ERX_SPACE_DEPTH_MAX` (64) deep below the first space, and a creation
beyond it fails with `ERX_ELIMIT`. The tree decides lifetimes and nothing
else: budgets nest in a tree of their own and groups in another,
supervision is the system domain's, and a job's membership is its
session's job table, so each of these relationships may differ from the
tree of spaces. A program's sub-space, by contrast, hangs under its
session's space or under another sub-space of the same session, as the
session arranges it, so that a program ends with the program or session
that started it, by the user's decision
([design-programs.md](design-programs.md#a-program-is-a-port)).

**The two walks.** Two operations visit a tree of spaces: the stop walk of
`erx_space_stop`, and the deletion walk of a space's destroy
([Threads and faults](#threads-and-faults)). Both are
iterative and need no stack, and each keeps its own position: the current
space, the space where it began, and the **held** space, the last it
descended into, which are all of it that survives a preemption point. A
walk counts the space where it began and the held space, and nothing else.
The current space is the held space or above it, so its record is kept by
the rule that a record outlives its children's (**Lifetime** below): going
back up reads the parent pointer and takes no reference. A walk takes the
reference to a space it descends into in the critical section in which the
space's parent's list names it, so the space has not reached its put, and
drops the reference to the space held before only afterwards. No path takes
a counted reference through a parent pointer, since the parent's last may
have gone already, leaving its record waiting for its children alone, and a
reference taken then would not keep it. They share each space's list of
children, which holds the children whose deletion has not begun, and two
facts about that list, which both walks keep:

* **Unfinished first.** In every list, the children whose stop walk is
  not done come before the **walked** ones, those of which every thread
  has its kill posted and every child is walked. A walk marks a space
  walked and moves it to the end of its parent's list in one critical
  section under the parent's lock; a creation adds a child at the front,
  under a parent that is not stopped; and a child that leaves the list
  keeps the order of the rest. A walk reads its first child and that
  child's mark under the same lock, so it never sees a walked child ahead
  of an unfinished one, and since a space not yet stopped is not walked,
  every running child is at the front too. A space's own `threads` list
  keeps the same order: the part that posts a thread's kill moves the
  thread to the end (**Unfinished first** under [Execution model and
  locking](#execution-model-and-locking)).
* **A child leaves its list when its deletion begins, and only then.**
  Every deletion of a space, the root's included, begins with one critical
  section under the parent's lock that closes the space, sets its table's
  emptied flag and unlinks it from its parent's list. So no list names a
  space whose deletion a walk has begun, each child is deleted by the one
  walk that unlinked it, and, since every path that frees a space deletes
  it first, no list names a freed space, which is why the list holds no
  counted reference.

At each step, which the pure `erx_stop_step` decides, a walk looks only
at the first child `c` of its current space `s`:

```text
stop walk, from r, which the caller has stopped
  if s has a thread with no kill posted:  post the kills of the first of
                                          them, a part, moving each to the end
  else if c exists and c is not walked:   stop c unless it is stopped; s = c
  else:                                   mark s walked, moving it to the end
                                          of its parent's list; if s is r, done;
                                          else s = the parent of s

deletion walk, from r, closed, whose stop walk the caller has just made
  if c exists:      begin deleting c, which closes and unlinks c; drain it,
                    empty its table, tear down its mappings, withdraw its
                    exit record and queue its put, in bounded parts; s = c
  else if s is r:   done
  else:             s = the parent of s
```

By the first fact, a walked first child means that every child of `s` is
walked, so the stop walk goes back up, and a thread at the front of `s`'s
list with its kill posted means that every thread of `s` has one; by the
second, an empty list means that every child's deletion is done or is
being run by the walk that unlinked it, so the deletion walk goes back
up. Each step is constant work, a part of kills or a space's own deletion
apart, which proceeds in bounded parts, and is followed by a preemption
point. The deletion of a space the walk reaches runs that space's own
parts and starts no walk of its own, so the walk stays iterative and
stackless. A stop walk descends into every child that is not walked,
whether another
walk stopped it or not, and posts whatever kills are still missing there:
it never relies on another walk to finish a subtree, since that walk's
thread may be throttled at a zero quota or never run again, so every
stopper's own walk ends with every thread of its tree killed, and its
wait for the records then depends on nothing but the finishing threads
(K18). Two walks in one subtree do the same work at most twice, a kill
posted twice being a later kill of a dying thread, and whichever reaches
a space's end first marks it walked. The deletion walk begins only once
its root is closed and its caller's stop walk of the root is done, so
every space below is stopped and walked, its threads killed, before any
table below is emptied, and it never leaves a running space below a table
it emptied (K27); on a tree already walked that stop walk is one step. A
deletion that overlaps a stop of the same tree is correct in either order.
A stopped space refuses new children with `ERX_EDEAD`,
and a closed one with `ERX_ESTALE`, which a creation checks under the
parent's lock, so the lists below a stopped space only shrink and every
walk ends. Two walks of overlapping trees share the work, since a space
stops once and each space is deleted by the walk that unlinked it, and
every walk runs to its end, as every call does, even when it stops its
caller's own space.

**Who owns a deletion.** The walk that takes a space off its parent's list
owns that space's deletion, whichever destroy closed the space first. A
space's own destroy, by `DESTROY`, by its release or by its budget's
destruction, closes it, drains it, stops it and walks it, and then begins
its deletion walk: if another walk had unlinked the space by then, the
begin says so and the destroy stops there, leaving the put to that walk.
A destroy whose close finds the space closed stops at once. A parent's
walk that unlinks a space closed by its own destroy drains it as well,
which is safe twice, since no one takes a closed object's existence lock.
A deletion walk can therefore return while another walk is still deleting
a subtree that the other walk unlinked first, such as a sub-space whose
release a thread of the dying tree was finishing; that walk deletes it to
the end. So a destroy guarantees that every space below is deleted by a
walk that runs to its end, its own or the one that unlinked that space
first, not that its own call deleted them all. That walk runs on its call's
time, so while its thread's group is unscheduled the spaces it has yet to
reach stay stopped and undeleted, and their capabilities answer
([Security](#security)); a thread killed meanwhile finishes the walk at the
finishing level.

A space's end is complete when its own threads can no longer act (K18) and
every child's end is complete: each space counts its children whose exit
records are not yet posted, and its own record waits for that count to
reach zero. So a creator never hears of a space's end while anything below
it can still run. The system domain's space, the first, is the parent of
every domain's space, so the system domain learns a domain's end only
after every sub-space the domain created has ended, and every domain ends
with the system domain ([The root task](#the-root-task)). A session
chooses the parent of each program's sub-space: its own space, or a
sub-space of its own under which a program's children hang, so that a
program's tree ends with it; a creation names any space below the caller's
as the parent, and the kernel asks nothing about how a creator arranges
its spaces ([design-programs.md](design-programs.md#a-program-is-a-port)).
A program never outlives the session that started it, by construction: the
session keeps no list for it.

**Lifetime.** A space lives while a capability names it and its parent
lives: a deletion of its parent deletes it. When its last capability goes,
the space is released, and its destroy runs in the
call that removed that capability, in bounded parts, as a deletion's
does. It first closes the space, which from then on takes no mapping,
child or thread, and drains it, waiting for any call still changing it,
as Fiasco's `Task::destroy` waits for the task's existence lock before
it unmaps everything (`task.cpp`). Then the space stops, with status
`ERX_EXIT_RELEASED` unless it had stopped already, and its stop walk runs;
its deletion walk then takes the space off its parent's list, the root of
that walk being one of the spaces it deletes, and the kernel empties its
table and withdraws an exit record not yet received; and the teardown walks
the space's mapping records and detaches each from its object as
`erx_vm_release` does, so a released memory object whose last mapping
this was is destroyed in the same call. The detached records go to the
reaper, and the pages and tables they held are released as
`erx_vm_release` releases them, every translation removed and the
space's ASID invalidated before any of them is freed (K9). The root
table alone, its entries cleared, stays: a finishing
thread of the space runs on its own CPU until its last switch, is
switched to with the space's root loaded, and runs kernel code alone,
through the kernel's own mapping, never returning to user mode (K18),
so the root it loads must exist and may map nothing. The walk then
deletes each space below by the same parts. Once
its exit record has been delivered or dropped, its put has run and its
last reference, the last finishing thread's among them, has gone, its
root table is released, its ASID retired and its record **ready to free**.
A deletion of the space destroys it the same way, and so does the stopgap
([design-stopgap.md](design-stopgap.md#deletion)).

**A space's record is freed only after every child's record.** A child's
parent pointer is valid for the child's whole life, so a record waits for
its children's, as a dead budget's tombstone waits for its child's
([Budgets](#budgets)). So any record held counted keeps every record above
it, and a walk's way back up, a creation's walk up the chain and the
parent's handle in a space's inspection read only live records by
construction, whatever other walks have begun or finished.

Objects still hold no counted references to each other: `holds` counts
records, and no call waits on it. It counts one for each child whose record
is not freed, which a creation adds under the parent's lock, and one for
the space's own record, until it is ready to free. The creation's caller
holds the parent counted, so the parent's own hold is still there and the
count never rises from zero. Each drop is one atomic subtraction, and the
one that reaches zero, whichever it is, lets the record go, so readiness
and the children's frees cannot race and nothing reads the two together.
A record takes its defined start straight after its allocation, its own
hold and no parent, so a creation refused before its attach ends by the
same steps as any other, with no child and no parent to drop.

The free has two steps on the reaper's path, never inside the call that
drops a last reference. The **readiness step** runs once per record, when
it is ready to free, and drops its own hold, leaving the record if a child's
remains. The **free step** runs when the count has reached zero, by the
readiness step or by the last child's free step: it drops the hold on the
parent before the memory goes, and when that was the parent's last, queues
the parent's free step as it queues any record free, retired on its own
CPU's list, without a second readiness step. So a chain of released spaces
goes one level per round, a grace period and the reap deadlines its CPU's
backlog needs, by a queue and never by recursion, and a chain is at most
`ERX_SPACE_DEPTH_MAX` long. The first space is never freed. What waits is
the record alone, since its root table and its ASID went when it was ready.

**Containment.** A space's capabilities never pass to another space,
since the type has no pass set (K24), and a creator's `erx_cap_pass` into
a space it created hands one on with `INSPECT` alone, so `CAPS` on a
space stays in its creator's table
(K17). A domain therefore gives only into its own space and its
sub-spaces, and every capability to a sub-space lies in its creator's
table or in the table of a space below its creator. When
the creator stops, every space below it stops, and when the creator is
deleted, every space below it is deleted by the walks of **Who owns a
deletion** (K27), so once they have ended no capability anywhere keeps a
sub-space past its creator, and no cycle of capabilities between
spaces can keep a deleted space alive.

**Memory shared with a sub-space.** A creator serves the code it runs in a
sub-space, so it follows the rule for servers
([Closing and deleting](#closing-and-deleting)): it gives the sub-space
memory without `DESTROY`, and reaches memory the sub-space created only
through `erx_mem_copy`, so nothing that code does can make its creator
fault.

**Faults.** A space's fault gate is a gate the creator holds with `SERVE`:
its own, or one whose server passed it `SERVE` so that faults go to a
designee. It is fixed at creation, and the label rides on every record
([Threads and faults](#threads-and-faults)).

**Inspection and accounting.** `INSPECT` on a space permits bounded
enumeration of descendant topology: object ids, parent, states and charges,
a page at a time with a cursor. It does not grant detailed access to a
child's registers, capability table, mappings or memory. Those queries
require the child's own capability with the required rights. A creator's
agent can query capabilities it holds and relay details, whose reporter is
then that runtime rather than an independent kernel observation. Separate
domains retain their own inspection scope even when parented below another
domain for lifetime purposes ([design-live.md](design-live.md#inspection)). A
sub-space's objects are charged to the budgets its creator named, so a
domain's charge includes its sub-spaces'.

**What this adds.** Space creation, ASID allocation, thread creation in
another space, mapping and capability installation into spaces the caller
created, and stop propagation are paths that any domain with `SPACES`
reaches, within its budget. Each is charged, bounded per part and the same
code that serves a domain's own space; the residual is that churning
spaces forces ASID rollovers, which [Security](#security) bounds.

### vCPU upcalls

The kernel delivers events to a worker as Fiasco delivers them to a vCPU,
through the subset of Fiasco's vCPU interface that `liberx` needs to take
signals ([design-programs.md](design-programs.md#signals-in-liberx));
erXos's own kernel implements the same subset.

**Arming.** `erx_vcpu_control(thread, flags)`, with `CONFIGURE`, arms the
thread for upcalls with `ERX_VCPU_ARM` and disarms it with 0, as Fiasco's
`vcpu_control` enables a thread's vCPU state. The state area is always the
one in the thread's kernel-user page, so the call names no address. It
fails with `ERX_ETYPE` for an executor, and a thread's class is fixed at
its creation, so preemption never runs runtime code (K20). An armed
thread's events are the IRQ objects bound to it; a worker of a POSIX
program binds exactly one, its signal IRQ object.

**When an event arrives.** A delivery of an IRQ object bound to an armed
thread is decided, on the thread's home CPU, by `erx_vcpu_step`, a pure
function of where the thread is and of the state word, which it loads
once:

| The thread is | Events enabled | Events disabled |
| --- | --- | --- |
| in user mode, ready to return to it, or in a call that does not wait | an upcall at its next return to user mode, after the call's results are in its registers | queued at the thread, pending flag set |
| in an open wait | received as a message with the IRQ object's label, as by any thread | the same |
| waiting on a umtx word | the wait ends, with `ERX_EINTR` as the call's result in the frame the upcall saves, and the upcall follows | queued, pending flag set; the wait goes on |
| in a call's send or reply phase | queued, pending flag set | the same |
| held at its return to user mode by a pause or a copy | queued, pending flag set; the upcall comes when the last hold goes | the same |
| stopped, or in a stopped space | queued | queued |

`erx_vcpu_step` also runs at every other event that changes what an armed
thread can take, so a delivery never stays queued while the thread could
take it, whatever path the thread took:

* **every return to user mode**, at the end of a call, after a wake, or
  after a stop when the thread is started again: with events enabled and
  a delivery queued, the thread enters the upcall instead of its frame,
  by row 4 of `erx_return_check` ([Threads and
  faults](#threads-and-faults));
* **entering a umtx wait** with events enabled and a delivery queued: the
  call does not wait, returns `ERX_EINTR`, and the upcall follows at the
  return;
* **entering an open wait**: a queued delivery is received as a message,
  as by any thread;
* **arming**: a delivery already queued at the thread is decided as one
  arriving then would be, so one queued before `ERX_VCPU_ARM` does not
  wait for the thread's next kernel entry;
* **disarming**: queued deliveries stay queued for the thread's next open
  wait.

So the send or reply phase of a call, in which a delivery only queues,
ends with the upcall at its return when events are enabled, and `liberx`
needs no check of its own at its exits (K29).

A call already under way is never abandoned for an event, as Fiasco's
vCPU interface abandons none, which keeps the rule of
[design-programs.md](design-programs.md#signals-in-liberx) that a request
already sent is never abandoned because of a signal. A thread that runs
on another CPU is brought to its return to user mode by the trigger's
cross-CPU request.

**The upcall.** At the thread's return to user mode, the kernel removes
the delivery from the thread's queue, writes the thread's user frame and
the event's label into the state area, sets `saved_state` to `state` and
clears `ERX_VCPU_EVENTS` in `state`, as Fiasco's
`vcpu_enter_kernel_mode` does, and enters user mode at `entry` with the
area's address in the first argument register and the stack pointer
unchanged, as Fiasco's upcall does outside vCPU user mode. The frame is
the state user code can set for itself: the general registers, the stack
pointer, the program counter and the status bits user mode can observe or
change, as the binding lists them
([design-arch-aarch64.md](design-arch-aarch64.md#thread-state)). The FP
and SIMD state and the thread-pointer registers stay live in the thread
(K11), and a handler saves the FP state it uses. An upcall disables
events, and the kernel makes none while they are disabled, so a handler
is interrupted by another upcall only if its own code enables events
again. That is user mode's choice, as in Fiasco: a second upcall
overwrites the frame in the state area, so `liberx` copies the frame out
before events are enabled again
([design-programs.md](design-programs.md#signals-in-liberx)). No kernel
guarantee rests on it: a frame holds only state user code can set for
itself, and every resume validates it.

**Resuming.** `erx_vcpu_resume()` loads the area's frame once, field by
field, into the thread's record and validates the copy: user mode in its
status bits and no bit the frame may not hold, as Fiasco sanitises a
resumed trap state; a malformed frame stops the thread with a fault
record. Then, in one step: if `saved_state` enables events and a delivery
is queued at the thread, the kernel takes it and enters the upcall again
with the frame unchanged; otherwise it sets `state` to `saved_state` and
resumes the frame. So no event is lost between a handler's last check and
its return (K29). Fiasco decides by the sticky pending flag, which user
mode may clear; erXos decides by its own queue and keeps the flag as a
hint for user code, which checks it after enabling events by hand. A frame
holds only state user code can set for itself, so a thread may resume a
frame other than the one delivered, which is how `liberx` enters its
trampoline.

**What the subset leaves out**, each for a reason:

* **Faults as upcalls.** Fiasco delivers page faults and exceptions as
  upcalls when the state word asks for them, bypassing the pager and the
  exception handler, and user mode can set that word at any moment.
  erXos's kernel reads those bits as zero, so every fault still reaches
  the space's fault gate (K28), and a creator sees every fault of its
  sub-spaces.
* **vCPU user mode.** Fiasco can run a vCPU thread in another task's
  address space and force every trap there to an upcall, L4Linux's model,
  which is the L4 way a domain could host a sub-space under a user-level
  kernel. No part of erXos needs it, and the state bit that asks for it
  must be zero.
* **Messages as upcalls.** Fiasco delivers any sender as an upcall when
  the thread is in no IPC operation. erXos upcalls only for IRQ objects,
  whose deliveries carry no words, so an upcall never overwrites the
  message registers of the code it interrupts; a message through a gate
  waits for the thread's next receive.
* **Control of the FP unit and virtual machines.** The FP state stays
  live, and erXos runs no guests.

Fiasco has no way to cancel a call in progress for a signal either, a gap
L4Re's own signal code notes (`l4re_itas/server/src/signals.cc`); erXos
needs none, because no wait of `liberx` blocks in a call for long
([design-programs.md](design-programs.md#signals-in-liberx)).

**Access.** Fiasco reads and writes the state area through a kernel alias.
erXos's kernel uses its own mapping of the kernel-user page as well, but
only through the shared-memory accessors: an upcall writes the frame and
the label, and a resume loads each field it decides on once and validates
the copy (K7). An upcall costs one copy of a fixed frame at a return to
user mode and adds no unbounded work to any path. `erx_vcpu_step` is
explored exhaustively on the host over every order of trigger, upcall,
resume, wait entry, return from a call, stop, start, hold, release of the
last hold, arming and disarm (K29); a QEMU test interrupts a thread that
computes, one that waits on a umtx word and one that waits for a reply,
and checks the restored frame register by register, with the FP registers
unchanged.

### IPC gates

IPC follows Fiasco: a message goes through an IPC gate to the one thread
the gate is bound to, at a rendezvous, and a thread's open wait receives
from every gate and IRQ object bound to it, telling them apart by label.

**Gates.** `erx_gate_create(budget)`, with `ALLOC`, makes an unbound gate.
`erx_gate_bind(gate, thread, label)`, with `SERVE` on the gate and
`CONFIGURE` on the thread, binds it to the thread with the label, as
Fiasco's `bind_thread` needs the special right on both; binding again
replaces the thread and the label, and binding to `ERX_CAP_NULL` unbinds.
A gate is bound only to a worker; an executor is refused with
`ERX_ETYPE`, since executors neither call nor wait to receive
([design-scheduler.md](design-scheduler.md#executor-class-enforcement)).
Fiasco replaces a label's two low bits with the rights of the capability
the sender used; erXos labels are the binder's in all 64 bits, and a server
that gives clients different authority gives them different gates. A
server tells its clients apart by binding one gate for each, each with
the client's label; the system domain's fault gates are gates like any
other.

**Calls and sends.** `erx_ipc_call(gate, tag, send_by, reply_by)`, with
`CALL`, sends the message in the caller's UTCB and waits for the reply;
`erx_ipc_send(gate, tag, send_by)` sends without waiting for a reply.
The deadlines are absolute monotonic times, one for the send phase and one
for the reply, as Fiasco gives each phase its own timeout; a deadline
already passed means not waiting at all. A send:

1. Resolves the gate's binding under its lock. An unbound gate holds the
   sender in its `att_blocked` queue until a binding wakes it to try again,
   the send deadline passes, or the gate goes, released or deleted
   (`ERX_ESTALE`).
2. Delivers to the bound thread on that thread's home CPU, through a
   cross-CPU request when it is another (K14). If the thread is in an
   open wait, the rendezvous happens at once: the words move with
   `erx_msg_copy` from the sender's UTCB to the receiver's, the items pass
   all or nothing ([Passing capabilities](#passing-capabilities)), the
   receiver learns the tag and the gate's label, and for a call the
   sender becomes the receiver's **caller** and waits in its reply phase
   until `reply_by`; the receiver serves on its own group's grant, so no
   call lends time ([design-scheduler.md](design-scheduler.md#service-work)).
   The receiver is made ready and the ordinary pick runs, which may pick it;
   no switch goes past the pick.
3. Otherwise queues the sender at the thread, with the gate's label fixed,
   by resolved urgency and then in arrival order, an IRQ delivery or an
   exit record queuing as a sender of `ERX_URGENCY_MAX`, as Fiasco queues senders by priority
   and in arrival order within one, and an IRQ delivery at 255, its
   highest (`ipc_sender.cpp`, `thread-ipc.cpp`, `prio_list.cpp`), until
   the thread next waits or `send_by` passes (`ERX_ETIMEDOUT`).

**Who owns a rendezvous.** The handshake runs on the receiver's home CPU,
in the request of step 2 or in the receiver's own wait when it takes a
queued sender: it finds the receiver in its wait, disarms the wait's
deadline and moves the receiver into a **transfer**, Fiasco's
`Thread_ipc_transfer` state (`handshake_receiver` in `thread-ipc.cpp`).
In a transfer the receiver takes no other sender, keeps the slots its
wait reserved, and is not woken by its space's stop or its deletion until
the transfer ends, as Fiasco's `Thread::do_kill` waits for one
(`thread.cpp`). The sending thread performs the transfer on its own CPU,
holding a counted reference to the receiver and passing preemption points
and helping as any call does, and ends it with one request to the
receiver's home CPU, which makes the receiver ready with the message, or
returns it to its wait when the pass failed, ending the wait at once if
its deadline passed meanwhile (`activate_ipc_partner`). So a receiver's
deadline either passed before the handshake, and the sender found no
wait, or ends nothing during the transfer, and every item's fate is
decided at one point, the install under the receiver's table lock, which
fills the reserved slots or, if the table has been emptied by then,
drops what it carried as a close would ([Passing
capabilities](#passing-capabilities)).

**Receiving.** `erx_ipc_wait(wait_by)` is the open wait. It reserves in
the caller's table as many slots as its buffer descriptor asks for, or
fails with `ERX_ELIMIT`, and takes the first sender queued at the thread,
or waits for one until `wait_by`; it returns the tag and the label, with
the words in the UTCB and each received item rewritten in place, and
releases the slots no item filled. An IRQ delivery arrives as a message of
no words with its object's label ([IRQ objects](#irq-objects)), and a
fault or exit record as a message from the kernel with its space's fault
label ([Threads and faults](#threads-and-faults)).
`erx_ipc_reply_wait(tag, wait_by)` replies to the current caller with the
message in the UTCB, ends the caller's call with `ERX_OK` and the reply,
and then waits as `erx_ipc_wait` does, the shape of every server loop;
`erx_ipc_reply(tag)` replies without waiting. A reply's items pass into
the slots the caller reserved for its reply phase. A reply with no caller
fails with `ERX_ENOCALLER` and, as in Fiasco, does not go on to wait.

**The caller.** A thread holds at most one caller, Fiasco's implicit reply
capability. The caller goes when it receives the reply; when its reply
deadline passes, its call ending with `ERX_ETIMEDOUT`; or when it dies or
its space stops; in each of the last two the server's reply later fails
with `ERX_ENOCALLER`. A thread that receives another call before it
replies drops its caller, whose call ends at once with `ERX_EDEAD`; Fiasco
logs that as an application bug and leaves the dropped caller waiting
until its own timeout. The server's death or its space's stop ends its
caller's call with `ERX_EDEAD`. Fiasco's optional explicit reply
capabilities, which let one thread hold several calls and reply out of
order, are not part of erXos: no erXos server defers a reply past its next
receive, and a server that serves calls concurrently binds a gate to each
of several threads.

**When a gate or a thread goes.** A waiter's status names what it waited
for. When a gate goes, released because its last capability went or
deleted, it is unbound and the senders blocked on it are woken with
`ERX_ESTALE`, the status a capability to a gone object returns, whichever
way it went. A sender already queued at the thread carries the label it
resolved and is still delivered, as in Fiasco, since the message was sent
while the gate was bound. When a thread dies, or its space stops, the
senders queued at it are woken with `ERX_EDEAD`, since their receiver is
gone, and a send through a gate still bound to it fails with `ERX_EDEAD`
until the gate is bound again.

**Executors** make none of these calls: each that may wait is refused to
an executor by the dispatch with `ERX_EWOULDBLOCK`, and `erx_ipc_reply`,
which does not wait, fails for an executor with `ERX_ENOCALLER`, since an
executor never receives and so never has a caller. A runtime reaches a
worker or a driver through shared rings and IRQ objects instead
([IRQ objects](#irq-objects)).

The transfer is a pure state machine, `erx_ipc_step`, over the sender's
and the receiver's states, explored exhaustively on the host with
deadlines, deaths, stops, rebinding and releases.

### IRQ objects

An IRQ object is Fiasco's: bound to one target with a label, fired by
software or by hardware, and delivered as a message of no words that
carries the label. erXos also binds one to a scheduling group, because
executors never wait in IPC: they park on their group
([design-scheduler.md](design-scheduler.md#park-and-wake)).

**Creating.** `erx_irq_create(budget, resource, kind, selector)`, with
`ALLOC` on the budget, makes an IRQ object with every right its kind
allows:

* `ERX_IRQ_SOFT` needs no resource; software triggers it alone. It is
  the doorbell of a lane, of a program's channel and of a pipe, and a
  worker's signal.
* `ERX_IRQ_LINE` takes a line of a resource held with `CARVE`. A line has
  at most one IRQ object (a second fails with `ERX_EBUSY`), and stays
  masked until its driver first acknowledges it, as a Fiasco interrupt
  stays masked until its first unmask. `erx_irq_route(irq, cpu)`, with
  `CONFIGURE`, routes it to a CPU of the root group's cpuset.
* `ERX_IRQ_MSI` takes the resource of a PCIe function, carved by its
  requester id ([Resources, DMA windows and
  consoles](#resources-dma-windows-and-consoles)), allocates a free line
  of the platform's **MSI frame**, and returns, with the object, the
  doorbell address and the value the function must write: for a confined
  function, at the I/O address at which every DMA window maps the frame
  ([DMA and the IOMMU](#dma-and-the-iommu)); for an unconfined one, at the
  device address the bridge's `dma-ranges` give the frame. The PCIe
  enumerator programs them into the function. A function has at most
  `ERX_MSI_MAX` (32) MSIs, beyond which the call fails with `ERX_ELIMIT`.

**Binding and triggering.** `erx_irq_bind(irq, target, label)`, with
`BIND`, binds the object to a worker thread, with `CONFIGURE` on it, or to
a group, with `SIGNAL` on it, and the label every delivery carries;
binding again moves it, and binding to `ERX_CAP_NULL` unbinds it. An
executor is refused with `ERX_ETYPE`, since its group's ready list is its
open wait. `erx_irq_trigger(irq)`, with `TRIGGER`, fires the object; it
never waits, so executors make it, and any number of holders may.
`erx_object_info` reports the binding to a holder of `INSPECT`, a right in
the IRQ object's pass set: whether the object is bound, the object id of
the thread or group it is bound to, and the label. Binding needs `BIND` on
the object and `CONFIGURE` or `SIGNAL` on the target, none of which ever
passes (K24), so a holder without `BIND` learns from the binding who chose
where its deliveries go: an object bound to a group was bound by a holder
of `SIGNAL` on that group, which no pass conveys.

**The state machine.** An IRQ object's life is a pure function,
`erx_irq_step(state, event)`, which returns the next state and the actions
to perform. It follows Fiasco's `Irq_sender` (`irq.cpp`): every fire of a
level-sensitive line masks it, as `_hit_level_irq` does; a fire of an edge
line or an MSI masks it while the object is unbound or a delivery already
waits, and leaves it unmasked when it queues the delivery, as
`_hit_edge_irq` does; an unbinding masks a line or an MSI, as
`detach_irq_thread` does; and `erx_irq_ack(irq)`, with `ACK`, unmasks only
while no delivery waits or is owed, as Fiasco's end of interrupt unmasks
only when `can_send()` holds. "Mask" and "unmask" act on a line or an MSI
and are nothing for a software object; for an edge line or an MSI the
state also keeps whether this machine masked it, as Fiasco's `Masked` flag
does:

| State | fire | bind | unbind | the delivery is taken | `erx_irq_ack` | release |
| --- | --- | --- | --- | --- | --- | --- |
| `UNBOUND`: no target | mask; a level-sensitive line stays `UNBOUND`, its fire dropped; any other kind becomes `PENDING` | `IDLE` | nothing | none waits | unmask | gone |
| `PENDING`: no target, one delivery owed | `PENDING`; mask | `QUEUED`: deliver | nothing | none waits | nothing | gone |
| `IDLE`: bound, nothing waiting | `QUEUED`: deliver; mask a level-sensitive line | `IDLE` with the new target | `UNBOUND`; mask | none waits | unmask | gone, leaving one delivery waiting at the target |
| `QUEUED`: bound, one delivery waiting | `QUEUED`; mask | `QUEUED`, the delivery moved to the new target | mask; the delivery withdrawn: `UNBOUND` for a level-sensitive line, `PENDING` for any other kind | `IDLE`; unmask an edge line or an MSI that this machine masked | nothing | gone, leaving the waiting delivery in place |

So a level-sensitive line interrupts at most once per acknowledgement,
which its driver makes once it has serviced the device, and an edge line
or an MSI at most twice per delivery taken: once to deliver, and once
more, masked, which keeps the edge pending at the interrupt controller
until the delivery is taken and the line unmasked, as Fiasco re-arms edge
interrupts. Whatever the device does, a level-sensitive line is masked
while a delivery waits or is owed, and an edge line or an MSI while a
delivery is owed or a second fire has come since its waiting delivery was
queued; the one fire it can still take while a delivery waits is the
second interrupt of that count. A trigger that comes while no delivery can
be taken is kept, and triggers that come meanwhile count once, as in
Fiasco: a delivery waits at its target until taken, a fire while one waits
adds nothing, and a fire while the object is unbound is owed to its next
binding. A withdrawn delivery is owed too, except a level-sensitive
line's, which is dropped: the line fires again once it is bound and
acknowledged if its device still asserts it, as Fiasco remembers only
edge-triggered interrupts ("Level-triggered IRQs must not be remembered",
`irq.cpp`).

A delivery is taken, and withdrawn, only on its target's home CPU, which
alone touches the target's queue (K14), so an unbinding or a rebinding of
an object whose delivery waits completes there, after any take that came
first, as Fiasco's unbinding aborts the send at the old target before it
marks the interrupt pending. The events reach `erx_irq_step` in the order
they took effect, and a delivery is taken only from `QUEUED`: the cells
marked "none waits" are not reachable.

**Delivery.** To a thread, a delivery joins the thread's queue of senders
as a sender of the highest urgency, behind only the senders of that
urgency queued before it, as in Fiasco, on the thread's home CPU (K14);
the thread's open wait takes it as a message of no words with the object's
label, and an armed thread may take it as an upcall instead ([vCPU
upcalls](#vcpu-upcalls)). To a group, a delivery lists the object in the
group's **ready list** under the group's park lock, advances the group's
epoch and wakes a parked executor; `erx_group_take_ready` takes it and
returns the label, so a runtime learns exactly which of its objects fired
since it last looked, each once, without polling any of them
([design-scheduler.md](design-scheduler.md#park-and-wake)). The list's
links and the queue's live in the IRQ object, so a delivery allocates
nothing. A thread that has died takes no delivery, as it takes no message,
and a deleted group takes none, since the insert functions refuse a
deleted object ([Objects and capabilities](#objects-and-capabilities)): a
refused delivery is fed to `erx_irq_step` as an unbind, so the object
drops its target and, unless it is a level-sensitive line, owes the
delivery to its next binding, and a dying thread or a deleted group
withdraws the deliveries already waiting at it the same way. A fire from
an interrupt runs in the interrupt handler, with interrupts masked, does
bounded work and makes no indirect call.

**Release.** When an IRQ object's last capability goes, it is unbound,
its line, if it has one, is masked and freed for a new object, and its
target receives its label once more: one delivery is left waiting there,
merged with one that is already waiting, and nothing can fire the object
again. A waiter whose doorbell is deleted therefore wakes once and finds
out, whatever the order of a last ring and the close. Fiasco
withdraws a waiting delivery when its IRQ object is deleted and delivers
nothing, so a ring just before a close could be lost
([L4 lineage](#l4-lineage)).

`erx_irq_step` is explored exhaustively on the host over every order of
fire, bind, unbind, take, acknowledgement and release, for each kind;
QEMU tests drive a virtio device's line and an MSI through bind, fire,
acknowledgement and release.

### Umtx

Waits keyed by a word's address, which musl's and ERTS's synchronisation
are built on, follow FreeBSD's `_umtx_op`, borrowing from Linux's futex
only where erXos needs what FreeBSD lacks:

* `erx_umtx_wait(addr, expected, deadline)` finds the word's key,
  compares the word with `expected` under the key's bucket lock, and
  queues the thread if they match; it returns `ERX_OK` when woken,
  `ERX_ETIMEDOUT` at the deadline, `ERX_EINTR` when an armed thread with
  events enabled receives an event ([vCPU upcalls](#vcpu-upcalls)),
  `ERX_ESTALE` when the word's object is destroyed during the wait, and
  `ERX_EFAULT` when the address is not mapped readable in the caller's
  space or maps a page that the kernel's direct map does not cover.
* `erx_umtx_wake(addr, count)` finds the key the same way, wakes up to
  `count` waiters on that word, in the order they queued, and returns how
  many it woke.

**The one address-keyed call.** These two calls take a user address,
because private memory, where ERTS's and musl's lock words live, has no
capability by construction (K5) and so cannot be named as a memory
window. The kernel still never loads through that address. The
architecture layer's one translate-and-read primitive, `erx_uword_load`,
walks the caller's own translation tables in kernel memory, a pure walk
that reads descriptors through the direct map, and yields the word's
physical page, or `ERX_EFAULT` for an address that no valid
user-readable entry maps and for one whose page the direct map does not
cover; only then does it load the word, with one atomic load through the
kernel's direct map of that page
([design-arch-aarch64.md](design-arch-aarch64.md#kernel-access-to-memory)).
The second refusal is one check of the page against the direct map's
ranges, which the boot records ([Boot](#boot)): whatever the direct map
leaves out, such as device registers, the boot image's slices or a
board's crash region, fails it, so no kind of object needs a rule of its
own and the load only ever reads RAM through the kernel's own mapping.
The walk decides before the load, so the call needs no user-copy loop,
no path that opens user access and no fixup table: there is no access
that could fault. A word that is not yet populated has no valid entry
and fails with `ERX_EFAULT`, which `liberx` answers by touching the word
and waiting again.

**A word's key.** A word's identity, its **key**, is the memory object
that its mapping names, private memory's object included, and the word's
offset in that object. Two spaces that map one shared object at
different addresses meet on its words, and private memory, mapped
exactly once (K5), has one address for each of its offsets. The kernel
keeps one table of `ERX_UMTX_BUCKETS` buckets, hashed from the key with
a key drawn at boot, so no domain can aim its words at the bucket of
another's; a bucket holds a queue per word, so a wake touches only that
word's waiters. One function, `erx_umtx_key`, takes a space and an
address to a key for both calls, and each of its steps runs under the
locks it names:

1. **Find the mapping**, under the space's lock. The mapping record that
   covers the address names the object and the word's offset in it; no
   record, a deleted one or one whose protection does not allow reading
   is `ERX_EFAULT`. The function takes the object's lock and releases the
   space's.
2. **Check the translation**, under the object's lock and the key's
   bucket lock, with interrupts masked and inside one read side of the
   kernel's read-copy-update. `erx_uword_load` walks the caller's tables
   and loads the word, or refuses as above, and the function checks that
   the page the walk found is the object's page at that offset or, for a
   copy-on-write child that does not own the page, its parent's. A page
   leaves an object only under the object's lock, so a page that passes
   the check stays the object's until the lock is released. A page that
   fails it means the mapping changed after step 1: the function releases
   both locks, passes a preemption point and starts again at step 1. Only
   a change to the mappings of the caller's own space causes a retry.
3. **Act**, under both locks still. A wait compares the word it loaded
   with `expected` and queues the thread on the word's queue, which it
   creates and links into the object's `att_words` through the object's
   insert function when the word has none, refusing a closed object with
   `ERX_ESTALE`, then releases both locks and sleeps; a wake takes up to
   `count` waiters off the queue and releases both locks.

So a wait's comparison and enqueue and a wake of the same word are
ordered by the word's bucket lock, and a store and wake that follow a
waiter's comparison find the waiter queued: the futex property holds. A
page that a range call or a deletion takes away from a space reaches the
free list only after a grace period that begins once its translations
have been invalidated (K9, [The reaper](#the-reaper)), so a walk that
races such a change reads a page, never freed memory, and step 2's check
discards what it read. Destroying the object, a private object with its
space included, finds every word's queue on its `att_words` and wakes
every waiter with `ERX_ESTALE` (K26). The locks are taken in the kernel's
order, the space's, then the object's, then the bucket's, a leaf
([Execution model and locking](#execution-model-and-locking)). An
executor may wait only on a word in its own private memory, which no
other domain can reach, and is refused on any other object with
`ERX_EWOULDBLOCK`
([design-scheduler.md](design-scheduler.md#executor-class-enforcement)).

The interface grows from FreeBSD's design where erXos needs more:
priority-inheritance and priority-protection mutexes, condition
variables, read-write locks, semaphores and robust lists, taking the
design and copying code only after review. Fiasco has no address-keyed
wait, and L4Re's pthread library keeps a kernel semaphore per thread
instead; erXos keeps musl's and ERTS's synchronisation as they are
([L4 lineage](#l4-lineage)).

### Passing capabilities

A space passes capabilities to another at a **rendezvous**: the moment a
message through a gate meets its receiver in an open wait, or a reply
meets its caller. The sender names in its message at most `ERX_MSG_CAPS`
(4) capabilities of its own table as typed items, each to be moved or
copied, with a rights mask; the receiver's buffer descriptor says how
many it accepts. The kernel installs them into the receiver's table in the
one operation that delivers the message, so a capability is never
anywhere but in a table: no queue, message, ring or pipe holds one,
nothing is in flight, and nothing needs collecting (K17). A sender queued
at a thread keeps its capabilities in its own table until the thread
takes its message. Executors make no IPC call, so runtimes pass
capabilities from workers.

1. **Reserving room.** A call that receives (`erx_ipc_call` for its
   reply, `erx_ipc_wait` and `erx_ipc_reply_wait` for the next message)
   first reserves as many free slots as its buffer descriptor asks for in
   its caller's own table, growing it within the space's capability limit
   and charging its pages to the space's budget, and fails with
   `ERX_ELIMIT` or `ERX_ENOMEM` before anything else happens. A reserved
   slot is neither free nor live: no value names it. The call releases the
   slots it did not fill when it returns, so a reservation lives only
   within one call.
2. **Planning.** At the rendezvous, the sending thread, which performs
   the transfer while the receiver is held in its transfer ([IPC
   gates](#ipc-gates)), looks up the values it names and takes the
   capability lock of each distinct object once, in address order, with
   `erx_object_lock_cap`, which looks each capability up again after
   every help, so two slots naming one object, or one value named twice,
   take that object's lock once, as Fiasco's `lock_cap_pair` does
   (`kobject_mapdb.cpp`); an object whose lock it already holds stays
   allocated through the helps the later locks need, since no slot that
   names it can be cleared meanwhile, and a holder never takes a helping
   lock again, which debug builds assert. Then it takes its table's lock
   and reads each named slot again, under its object's capability lock,
   which guards every slot that names the object, so a capability closed
   or an object deleted while it waited fails the plan with
   `ERX_ESTALE`. `erx_pass_plan`, a pure function, decides the
   whole pass from what it read: the count is at most the receiver's room
   (`ERX_ELIMIT`); each value names a live slot of an object not closed
   (`ERX_ESTALE`) and no slot is named twice (`ERX_EINVAL`); each
   capability carries `GIVE`, and a copy also `DUP` (`ERX_ERIGHTS`); its
   type's pass set is not empty (`ERX_ETYPE`). Each passed capability
   keeps its rights intersected with the sender's mask and with its
   type's pass set (K24), except in a creator's `erx_cap_pass` into a
   space it created (**The creator's rule** below).
3. **Taking.** If the plan accepts, `erx_pass_take` performs it under
   the sender's table lock: it checks every source slot and the size of
   the receiver's reservation again and changes nothing if either has
   moved, and nothing after this step fails. A copy adds a slot to its
   object's list, as a Fiasco map of a capability does. A move puts the
   receiver's slot
   in the place of the sender's in the list and clears the sender's slot
   through `erx_cap_slot_clear`, which hands the object's capability count
   to the receiver's slot instead of dropping it (K21). What the sender
   mapped through the moved capability stays mapped, since a mapping keeps
   its object, not the capability it was made through.
4. **Installing.** Under the receiver's table lock alone, after the
   sender's is released, `erx_pass_install` fills the reserved slots in
   the sender's order, and writes each item's
   value in the receiver's table, its type and its rights back into the
   receiver's message registers. If the receiver's space has ended and its
   table has been emptied, it fills nothing and drops what it carried, as
   a close would.

**A pass that fails changes nothing**: the sender gets the status and
keeps every capability it named, and the receiver goes on waiting.

* A send that meets a waiting receiver and fails returns the status to
  the sender at once, and the receiver stays in its wait.
* A queued sender whose pass fails when its receiver takes it is woken
  with the status, and the receiver takes the next sender.
* A reply whose pass fails returns the status to the server without
  receiving, and the caller stays its caller, so the server can reply
  again, for example with an error and no capabilities.
* A reply to a caller that timed out or died passes nothing: the server
  gets `ERX_ENOCALLER` and keeps its capabilities.

A pass holds at most four object locks, then one table's lock at a time,
and does at most four lookups and four fills. `erx_pass_plan` is explored
exhaustively on the host together with `erx_ipc_step`, over every order of
sends, receives, replies, deadlines, deaths, closes and deletions by the
sender's other threads, and the emptying of either table.

**Passes between two tables.** `erx_cap_pass(from, to, n)`, with `CAPS`
on both spaces, which differ, runs the same plan and the same two steps
from one space's table into another's, reserving its slots in `to` first.
Its `n` items are typed items in the caller's UTCB, as a message's are,
and the call rewrites each in place with the value, type and rights it has
in `to`'s table, as a rendezvous rewrites a receiver's items, so its
results are in the kernel-user page before the call returns and nothing
can leave a pass made but unreported. Its copies are slots of their own.

* **Who makes it.** `CAPS` on a space other than the caller's own is held
  only by that space's creator (K17), so only the system domain passes
  into domains, and a domain into its sub-spaces. The system domain
  passes a domain its initial capabilities and its devices at the
  domain's creation, objects it created for that domain and never one
  of another domain's ([Rights](#rights),
  [design-system.md](design-system.md#creating-a-domain));
  a session passes into a program's sub-space, at its start, the
  capabilities its starter derived for it, and after a fork what the child
  is to hold besides its copy
  ([design-programs.md](design-programs.md#the-channel)); since copies are
  slots of their own, a program keeps what it inherited when its starter
  closes its own.
* **The creator's rule.** When `to` is not the caller's own space, and so
  is a space the caller created, the pass sets do not bind: each
  capability keeps its rights intersected with the item's mask alone,
  which is how code, devices and the structure of spaces reach a space,
  from its creator and from nowhere else (K24). Two rights stay out even
  then: a space's capability passes with `INSPECT` alone, so `MAP`,
  `THREADS`, `CAPS` and `STOP` on a space never leave its creator's table
  (K17), and `CODE` never passes, so it stays in the system domain's
  table ([Rights](#rights)). Every other pass, at a rendezvous or by
  `erx_cap_pass` into the caller's own space, keeps each type's pass set.
* **`GIVE`.** When `from` is not the caller's own space the pass needs no
  `GIVE`, since the holder of `CAPS` on `from` could already close what it
  moves, which is how a session moves into a program what the program may
  keep but not pass on. From the caller's own space it needs `GIVE` on each
  capability, and `DUP` on each it copies, as a rendezvous does, so a space
  hands its sub-spaces only what it could hand on anyway.
* **Checked kinds.** Each item may also name the type its capability must
  have and rights it must carry, which the plan checks as every lookup
  does (`ERX_ETYPE`, `ERX_ERIGHTS`). So a creator that takes an object out
  of a sub-space's table knows its type and rights before it holds it,
  and learns who bound an IRQ object from its binding, which
  `erx_object_info` reports to a holder of `INSPECT` ([IRQ
  objects](#irq-objects)): an object bound to a group was bound by a
  holder of `SIGNAL` on that group, which never passes, and a doorbell
  moved without `BIND` keeps its binding.

**What never passes between peers.** Budgets, spaces, threads, groups,
resources and DMA windows have empty pass sets: what they convey (memory
and CPU, the structure of spaces, devices) reaches a space only by its
creator's pass, and a space's own capability with `INSPECT` alone, so the
structure of a space stays in its creator's table (K17). A memory object
passes without `EXEC`, `JIT`, `PHYS`, `SUPPLY`, `CARVE`, `SYSTEM` and
`DESTROY`, so the right to execute reaches a domain only from the system
domain, and no pass conveys a device address or the authority to fill,
grow or seal an object others read, or to report its stores; a JIT
object carries no `DUP` or `GIVE`, so no space writes code that another
executes. A gate passes without `CONFIGURE` and `DESTROY`, and an IRQ
object without `BIND`, `ACK`, `CONFIGURE` and `DESTROY`, so a doorbell
passed between peers can be rung and nothing else; a lane's doorbell
reaches its producer by the system domain's own install, with `TRIGGER`
alone ([Messages, gates and IRQ objects](#messages-gates-and-irq-objects)).

**Charges.** A passed object stays charged to the budget that paid for
it, and the kernel keeps nothing alive for a receiver: a receiver maps and
uses what it is passed while that budget lives, and when the budget is
destroyed the object dies with it, every receiver's capability fails the
one lookup and every mapping of it faults (K3, K26). Which budget a
cross-domain object is charged to is the system's rule, not the kernel's:
the system domain charges each to an outer budget or to a child budget
carved from one, so the death of one domain deletes nothing another maps
([Budgets](#budgets), [design-domains.md](design-domains.md#connections)).

**Who holds what.** `erx_object_info` reports each capability's object id,
so the inspector, which holds `INSPECT` on every domain's space, relates
the capabilities of different tables to one object without a registry of
holders ([design-live.md](design-live.md#inspection)).

**Relation to L4.** This is L4's capability transfer: Fiasco passes object
capabilities inside an IPC as typed items, each mapping (copying) or
granting (moving) one capability into a receive window the receiver named,
and also lets a holder of two task capabilities map from one task to the
other with `Task::map`, which `erx_cap_pass` corresponds to; as in Fiasco, a copy is a slot of its own, not a child of
its source ([Closing and deleting](#closing-and-deleting)). erXos departs
in three places, each for a reason. The receiver names a count rather
than slots, because the kernel assigns slots and their generations (K1).
A pass is all or nothing, where Fiasco transfers items one at a time and
leaves the earlier ones transferred when a later one fails, so a failed
call changes no table. Pass sets keep code, devices and the structure of
spaces from passing, which Fiasco leaves to each holder's masking (K24).
Four capabilities a message cover erXos's
uses, which pass a buffer, a gate or a doorbell at a time, and keep the
operation's bound small.

**Why not queued.** Unix's `SCM_RIGHTS` and Zircon's channels queue
capabilities in messages, where they belong to no table. Queues can then
hold each other's ends in cycles that no process can reach, so Linux keeps
a garbage collector for descriptors in flight, and a race in it,
CVE-2021-0920, was exploited in the wild on Android. A rendezvous leaves
nothing in flight, at the cost of a sender that waits for a receiver, as
every call already does.

### Closing and deleting

Capabilities are flat, as in Fiasco's object space: every capability to an
object is an equal slot on that object's list, and none is derived from
another (K25). A copy, by `erx_cap_dup`, a pass or a fork, adds a slot; a move puts the new slot in the old one's place;
closing removes one slot and nothing else.

* `erx_cap_dup(c, mask)`, with `DUP`, adds a copy to the caller's own
  table, with its rights intersected with `mask`, as Fiasco's map of a
  capability within a task does.
* `erx_cap_close(c)` removes `c` alone, as Fiasco's unmap of the caller's
  own capability does: other copies stay, and so do the mappings made
  through `c`, which keep their object ([Memory](#memory)).
* `erx_object_destroy(c)`, with `DESTROY`, **deletes** the object for
  every holder, Fiasco's delete with the delete right: every capability to
  it stops working at once, every mapping of it is removed, and the
  threads queued on it wake, with `ERX_ESTALE` for an object they waited
  on and `ERX_EDEAD` for a thread they were sending to (K26). Destroying
  a group, by `DESTROY`, by its budget's destruction or by its parent's,
  destroys its child groups, kills its member threads, as a thread's
  deletion kills it, unbinds its IRQ objects and withdraws the deliveries
  waiting on its ready list, since a thread whose group is gone has
  nothing to run on; each killed member keeps its counted reference on
  every group of its path until its last switch, so the records outlive
  the destroy only as long as their members' remaining calls, which run
  at the finishing level on their own CPUs, within each CPU's finishing
  share and outside every quota, charged for the accounting to the
  `finishing_ns` of those same groups, as a stop's finishing threads are
  to theirs ([Execution model and locking](#execution-model-and-locking)),
  so a zero grant, the destroyed group's or the destroyer's, holds
  nothing back; destroying a space, by `DESTROY`, by its release, by its
  budget's destruction or by its parent's, deletes every space below it,
  each by the walk that unlinks it;
  deleting a memory object
  deletes its copy-on-write children; deleting a budget deletes every
  object charged to it and every budget carved from it
  ([Budgets](#budgets)). A fault gate may be deleted like any gate, and a
  space's later records are then dropped and counted, as when the gate
  is released ([Threads and faults](#threads-and-faults)).
* Emptying a table, at a space's end or its release, closes each of its
  capabilities; what the space passed to others stays with them while
  the budget that pays for it lives.

**Taking back what was given.** A giver takes something back by deleting
it, which takes it from every holder, the giver included. `DESTROY` never
passes between peers (K24), so only the space that created an object, or
a space its creator passed the right to, decides when it goes, besides
the holder of `DESTROY` on the budget that pays for it. To cut
off one holder and not another, a giver gives each holder an object of
its own, as L4Re's servers give each client its own gate: the system
domain creates a connection's objects, its two lanes' rings, reader pages
and doorbells, for one pair of domains and deletes them to take the
connection down ([design-domains.md](design-domains.md#connections)), and
a session makes
each pipe's ring for the programs it maps it into
([design-pipes.md](design-pipes.md#making-a-pipe)).

**Deletion, step by step.** Deletion is Fiasco's two-phase destruction
(`kobject.cpp`):

1. **Destroy.** The destroy closes the object, drains it and tears it
   down ([Execution model and locking](#execution-model-and-locking)):
   1. **Close.** It invalidates the object's existence lock, as Fiasco's
      `initiate_deletion` does. `erx_cap_lookup` fails every capability
      whose object is closed, with `ERX_ESTALE`, the insert functions
      through which everything attaches to an object refuse it, and no
      operation can take its existence lock, so from this store on no
      call reaches the object and nothing attaches to it, however many
      slots still name it.
   2. **Drain.** It waits until the existence lock is free, helping the
      operation that holds it, as Fiasco's `destroy` does in `wait_free`,
      so nothing that began before the close is still changing the
      object.
   3. **Tear down.** It runs the type's teardown, in bounded parts with
      a preemption point after each: it clears every slot on the object's
      list through `erx_cap_slot_clear`, which advances each slot's
      generation (K1); marks every CPU mapping of the object
      `ERX_MAP_DELETED`, removing its translations and invalidating the
      TLB; removes every DMA mapping, completing the IOMMU's
      invalidation; and wakes every thread queued on the object through
      `erx_wait_complete`; a queued thread holds no reference to the
      object (K33) and reaches it again only through a fresh lookup,
      which fails.
2. **Grace period.** The kernel queues the put of the object's own
   reference behind a grace period, retired as every put is to the
   period that begins after the close (**Stamps**, [The
   reaper](#the-reaper)), which ends once every active CPU has returned
   to user mode, idled or passed a preemption point since, so no call
   that looked the object up before the close still uses it
   ([Execution model and locking](#execution-model-and-locking)).
3. **Put.** After the grace period the reaper drops the object's own
   reference. When its last counted reference goes, the record is freed
   and its slot returns to its budget's cache; the object's pages, in
   use or in its reserve's pool, were released by its teardown, their
   charge ending there, and wait out a grace period of their own on the
   released list ([The reaper](#the-reaper)).

**Deleting a thread.** A thread's teardown has two parts, as Fiasco's
does. The deleting call closes and drains the thread, clears its slots,
posts the kill to the thread's home CPU, a kill that names no group, the
thread's finishing being added to the `finishing_ns` of its own path as
every finishing is, and returns, as Fiasco's
`Thread_object::destroy` waits for the existence lock and then kills
(`thread_object.cpp`) and `Thread::kill` returns once it has posted the
kill (`thread.cpp`): from the close on no lookup reaches the thread and
nothing new attaches to it (K26). The thread runs the rest itself, on its
own stack, once the call it is in has ended, a wait being cut short as for
a stop, at its return to user mode, where a death comes before a hold
(**The return to user mode** in [Threads and
faults](#threads-and-faults)). It wakes the senders queued at it with
`ERX_EDEAD`, a bounded part at a time; ends the call it serves, whose
caller is woken with `ERX_EDEAD`, where Fiasco's dying thread leaves the
caller waiting ([L4 lineage](#l4-lineage)); withdraws the deliveries
waiting at it, each fed to `erx_irq_step` as an unbind ([IRQ
objects](#irq-objects)); leaves its group's member list, which frees its
executor slot if it still holds one and keeps its references on the
groups of its path, which its remaining time is still charged to
([design-scheduler.md](design-scheduler.md#park-and-wake)); and drops its
reference to its space, whose thread count falls there ([Threads and
faults](#threads-and-faults)). It unbinds what is bound to it: each gate
on its `att_bound` is left bound to no thread and marked dead, so a send
through it fails with `ERX_EDEAD` until it is bound again ([IPC
gates](#ipc-gates)), and each IRQ object there is fed to `erx_irq_step` as
an unbind ([IRQ objects](#irq-objects)).
It then waits out a grace period before its last switch, as Fiasco's
`Thread::do_kill` calls `rcu_wait` after the same detachments: the parties
it detached from reached it without counted references, and the grace
period that began at the close does not cover what they did after it. What
keeps its record and kernel stack alive through all of this is a counted
reference of its own, the **dying reference**, which the kill takes on the
thread's home CPU when it marks the thread dying, once, whichever of a
deletion, a release and its space's stop comes first, as Fiasco's
`Thread::prepare_kill` takes one (`inc_ref` in `thread.cpp`). So the put
that ends the deletion's own grace period never frees a thread that is
still finishing its call, tearing itself down or waiting out its second
grace period. After its last switch away, the CPU drops the dying
reference and the references on the groups of the thread's path from
its own context, never on the dead thread's stack, as Fiasco's
`handle_kill_helper` does from the kernel's context, and releases the
stack; the record goes to the reaper once the last counted
reference has gone. A thread released, when its last capability goes, and a thread of a
stopped space run the same second part.

**The release rule.** An object is **released** exactly once, when its
last capability goes, however it goes: a close, a deletion, or the
emptying of its holder's table (K21). Its capability count changes only
in `erx_cap_slot_clear` and in the installs of creations, copies and
passes, and a move hands the count from slot to slot within one
operation, so a moved capability never passes through zero. A released
object is destroyed the same way as a deleted one, without being deleted,
for every type but memory and groups. A memory object lives on while a
mapping of it remains, so a space that closed its capability keeps what
it mapped, as a Unix process keeps a mapping of a file it closed; the
object is destroyed when its last mapping goes, or when it is deleted. A
group lives on while it has member threads or child groups, and is
destroyed when the last of them goes, so no executor is ever left in a
group it can no longer park in. A counted reference, which only a thread
holds, across a preemption point, never a wait (K33), or, on the groups
of its path, for its whole life, keeps the record but never delays the release, and an attachment keeps nothing. Who learns of a release is not the kernel's: the system domain
tells a domain that a connection is down, and a session knows every
holder of its pipes and channels because it installed each of them
([design-domains.md](design-domains.md#connections),
[design-pipes.md](design-pipes.md#making-a-pipe)). The release core is
explored exhaustively on the host over closes, moves, deletions and the
emptying of tables, and checks that every object is released once, only
after its last capability.

**Deleted memory faults.** A mapping record of a deleted object stays in
its space, marked `ERX_MAP_DELETED`, with no translation, until the space
releases its range, and every access to it faults with kind
`ERX_FAULT_DELETED`. The fault is reported like any other: the thread
stops and its record goes to its space's fault gate, so a program ends
with `SIGBUS`, as a Unix process does when it touches a mapping of a file
that was truncated ([design-programs.md](design-programs.md#a-programs-end)),
and an Erlang domain ends and its supervisor restarts it
([design-system.md](design-system.md#ending-a-domain)). A DMA mapping of a
deleted object is removed, so DMA in flight aborts at the IOMMU and the
driver sees a device error, never a write to a freed page. An access to
memory that is gone is a bug or an attack, and it shows as one, at the
instruction that made it.

**The rule for servers and drivers.** A space that serves others is never
one deletion away from a fault:

* **A server maps only memory no client can delete, and none that a
  client's end deletes:** memory it created itself, charged to its own
  budget, and memory the system domain created for a connection and
  keeps the delete right to, charged to the child budget of a domain's
  outer budget for that connection, which the system domain destroys
  only once both parties have let go ([Budgets](#budgets)).
  Clients receive such memory without `DESTROY`, which no pass between
  peers conveys anyway (K24), and a domain holds no capability to its
  outer budget, so no client can make a server fault, by a deletion or by
  its own end.
* **Memory a client owns, a server only copies.** `erx_mem_copy(dst
  (WRITE), dst_offset, src (READ), src_offset, len)` copies between two
  memory windows through the kernel's own mappings, in parts of at most 64
  pages, and fails with `ERX_ESTALE` once either object is deleted, so a
  client that deletes its memory in the middle of a request costs the
  server an error, never a fault ([Arguments and
  results](#arguments-and-results)). The server copies into memory of its
  own that it maps, as a lane's reader copies a frame into private memory
  before it looks at it. `erx_mem_copy` and `erx_mem_supply` refuse
  physical memory with device attributes and JIT objects (`ERX_ETYPE`),
  since a kernel access to a device whose link has dropped would abort in
  kernel mode ([Interrupts, time and
  entropy](#interrupts-time-and-entropy)) and the kernel writes no code.

erXos's data paths follow the rule: a domain maps a lane's ring and
reader page, which the system domain creates for the connection, charges
to the connection's child budget of the reader's outer budget and holds
the delete right to ([design-domains.md](design-domains.md#connections));
a driver's buffers lie in memory its own domain created, and what it
hands a client in another domain travels over their connection; and
programs map
the pipe rings and channel pages their session created
([design-pipes.md](design-pipes.md#the-ring),
[design-programs.md](design-programs.md#the-channel)). A sub-space's
creator follows the same rule towards the code it runs there
([Creating spaces](#creating-spaces)).

**Copy-on-write children.** A child is made only from an immutable object
([Copy-on-write children and copies of
spaces](#copy-on-write-children-and-copies-of-spaces)), and is a new object
with a list of its own, attached to its parent object, on the parent's
`att_children`, rather than to a capability. A child reads the pages it
does not own from its parent, so it lives no longer than the parent:
destroying the parent, by a deletion or by the destruction of its budget,
deletes every child, and their mappings fault from then on; a parent
released while children remain lives on until the last of them goes, as
it lives on while a mapping remains. A giver takes back the children made
from what it gave by deleting it.

**Work already queued.** A message already queued, or a call already in
service, when the sender's capability goes completes or times out as it
would: closing and deleting act on what capabilities allow from then on.
The queue links the sending thread's own record, and holds a counted
reference to that record while it does, never to the capability the
message went through, so closing that capability leaves nothing in the
queue pointing at it ([Passing capabilities](#passing-capabilities)).

**Relation to Fiasco.** This is Fiasco's object space: Fiasco's l4sys
headers state that object capabilities are not hierarchical and have no
children (`l4sys/include/consts.h`); `kobject_mapdb.cpp` keeps, per
object, the list of slots that name it, mapping a capability appends a
slot, an unmap removes only the caller's own, and deletion with the
delete right empties every slot; an object then goes through `destroy`,
an RCU grace period and `put` (`kobject.cpp`). The stopgap uses Fiasco's
own object space as it is
([The current implementation](#the-current-implementation-the-modified-fiasco)).
Two details are erXos's: the kernel assigns slots and their generations
(K1), and memory is reached through memory objects rather than Fiasco's
mapping database, so deleting a memory object plays the part of Fiasco's
recursive unmap of a dataspace's pages, and the access that follows
faults to the space's fault gate, since erXos has no pager
([L4 lineage](#l4-lineage)). A
derivation tree for every
capability, as in seL4, was considered and declined
([Alternatives considered](#alternatives-considered)).

The deletion core, `erx_delete_step`, is explored exhaustively on the
host over copies, moves, closes, deletions, table emptying and lookups and
attachments racing a deletion, and operations that hold the object's
existence lock, and checks after every step that no lookup, attachment or
taking of the existence lock succeeds after the close, that no operation
holds the existence lock once the drain has ended, that a deletion and a
release that race tear the object down once, that every slot, mapping,
binding and waiter of a deleted object is gone once its teardown
completes, and that no record is freed before its grace period has ended.

### Virtual memory

* **Placement.** Calls that create mappings take an address and flags.
  Without `ERX_VM_FIXED` the kernel maps at the address when that range is
  free and page-aligned, above the placement base or below it, and otherwise
  picks the highest free range below the space's placement base, chosen at
  random when the space is created (fixed in deterministic mode), so
  successive mappings stay together and share translation tables. An address
  that is unaligned or outside the user half is ignored, not refused. With
  `ERX_VM_FIXED` the range starts exactly at the address and replaces
  whatever the space mapped there, unless `ERX_VM_NOREPLACE` makes an overlap
  fail with `ERX_EEXIST`; `ERX_VM_NOREPLACE` without `ERX_VM_FIXED` fails with
  `ERX_EINVAL`. A creating call fails with `ERX_ENOMEM` when no free range of
  the size lies below the placement base, since the kernel's own search never
  goes above it, where fixed images and `ERX_VM_FIXED` callers put things, or
  when the space already holds `ERX_MAPPINGS_MAX` records.
* **Who pays.** The budget of the space that holds a mapping pays for the
  mapping record, the translation tables that cover it and the private
  memory committed in it, whoever makes the call, through the space's
  reserve. A shared object's pages are charged to the object's budget
  when it is created, and a page is counted once, at the object that
  owns it: a mapping of an object charges the mapping space only its
  records and tables, however many spaces map the object, and a
  copy-on-write child's own pages are the child's while its parent's
  pages stay the parent's. A record *holds a promise* of its tables unless
  it is a reservation: private memory, a mapping of an object, a deleted
  mapping and a kernel-user page all do.
* **Reserve.** `erx_vm_reserve(space, addr, size, flags)` creates a
  reservation: private memory with no access and no pages. It costs one
  record and nothing else, whatever its size: address space is not
  memory, so a reservation larger than the budget's cap succeeds, and
  what it will hold is charged only when a commit, or a protect that
  gives it access, promises the pages.
* **Commit.** `erx_vm_commit(space, addr, size)` makes reserved memory
  readable and writable, and committed memory in the range, whatever its
  protection, becomes read-write. It first adds to the space's reserve every
  page that populating the range can need: its data pages, and at each level
  of translation table below the root one table for every region of
  that level that the range touches and no record that holds a promise
  touches already; the root comes with the space, and the binding
  gives the levels and the region each table covers
  ([design-arch-aarch64.md](design-arch-aarch64.md#translation)). So the
  space's reserve holds, at every moment, one table for every region a
  record that holds a promise touches, whether the table is built or its
  page waits in the pool. Both this call and `erx_vm_decommit` act on private
  memory, reserved or committed, and holes; a mapping of an object, deleted
  or not, or a kernel-user page in the range ends the call with `ERX_EEXIST`,
  the parts before it applied, as does `ERX_ENOMEM` for a split that would
  pass `ERX_MAPPINGS_MAX`. Each part of the call charges its pages through the
  space's budget and backs them before it edits its records, in parts of
  at most 64 pages ([The reaper](#the-reaper)): a budget that cannot
  cover the part fails the call with `ERX_ENOMEM` and the parts before
  it stay applied, and a charge once admitted is always backed, so a
  page that a fault in the committed range can need is in the space's
  pool before the range is readable.
* **Decommit.** `erx_vm_decommit(space, addr, size)` returns committed
  memory to no access and releases, with their charge ending there
  ([The reaper](#the-reaper)), its data pages, populated or still in the
  pool, and the table of every region the range touched that no record
  that holds a promise touches any more, built or in the pool; the range
  stays reserved, and committing it again yields zeros. It meets only
  private memory (**Commit** above), so it never touches a shared page.
* **Protect.** `erx_space_protect(space (MAP), addr, size, prot)` sets
  the protection of every mapping in the range to `prot`, splitting at
  most the two records that straddle the range's ends, and keeps every
  page and its contents. `prot` is `ERX_PROT_NONE`, `ERX_PROT_R`, `_RW`
  or `_RX`, and any other value, write with execute among them, fails
  with `ERX_EINVAL` before anything changes. Each mapping moves only
  beneath its own ceiling: the call proceeds a part at a time, as the
  other range calls do (**Bounded range calls** below), and each part
  does three things in a fixed order, each before anything of the part
  changes. First it checks `prot` against the ceiling of the mapping it
  meets, a reservation's being private memory's, read-write: a ceiling
  that does not include `prot` ends the call with `ERX_ERIGHTS`, and a
  hole ends it with `ERX_ERANGE`, so `ERX_PROT_RX` over a reservation is
  refused with nothing committed; it is the one range call over mixed kinds,
  a kernel-user page alone ending it with `ERX_EEXIST`, and a split that would
  pass `ERX_MAPPINGS_MAX` ends it with `ERX_ENOMEM`. Then, if the mapping is a reservation
  and `prot` is not `ERX_PROT_NONE`, it commits the part as
  `erx_vm_commit` does, charging the part's reserve to the space's
  budget, and ends the call with `ERX_ENOMEM` when the budget cannot
  cover it. Last it sets `prot`. The parts before a failed one stay
  applied, as POSIX allows of a failed `mprotect`. So reserving address
  space costs nothing, and a program that maps with no access and later
  asks for access pays at the `mprotect`, as it does on QNX and Linux
  ([design-programs.md](design-programs.md#the-posix-lite-personality)).
  A reservation that is set to `ERX_PROT_NONE` stays a reservation, and
  committed memory set to `ERX_PROT_NONE` keeps its pages, their
  contents and their charge, since only a decommit or a release gives
  them up. Lowering a protection clears the range's translations in
  place, by the table step of **The edge rule** below, through the
  invalidation plan of K9, whose last step folds a shared object's dirty
  entries into its stored marks (**Store tracking** below); it detaches
  no table, since every promise that reserved one stays, so a fault
  rebuilds a translation with the protection the call set from the
  space's pool alone (K6). Besides the commit of a reservation it gives
  access to, the call charges only the records a split needs, to the
  space's budget.
* **Release.** `erx_vm_release(space, addr, size)` removes every record in
  the range from the space in one atomic step: it splits the at most two
  records that straddle the range's ends and detaches the records between
  them as one subtree, so no access, fault or range call of the space
  reaches them from then on. A kernel-user page in the range fails the call
  with `ERX_EEXIST` before anything moves, and a split that would pass
  `ERX_MAPPINGS_MAX` with `ERX_ENOMEM`. The call then walks the subtree in
  bounded parts, with a preemption point after each: each record of an object
  leaves the object's reverse map under the object's lock, so the call
  that removes a released memory object's
  last mapping is the call that destroys it ([Closing and
  deleting](#closing-and-deleting)). A record leaves the reverse map
  once, by whichever of the release and a deletion of its object reaches
  it first, and a detached record has no translation left for a deletion
  to remove. The records then go to the reaper, and the pages they held,
  the tables of the regions no record that holds a promise touches any more,
  and the pooled pages of the promises that ended are released, their charge
  ending at once, so the space's reserve falls and its budget's `used`
  with it.
* **Map.** `erx_vm_map(space, addr, size, memory, offset, prot_flags)`
  maps a shared, contiguous, physical, sealed paged or copy-on-write object
  through a capability of the caller's table, into a space the caller
  holds with `MAP`. It holds the space's existence lock throughout, as
  Fiasco's `fpage_map` holds the destination task's. It fixes the
  mapping's ceiling as the capability's rights intersected with the
  object's ceiling, refuses a protection above it, refuses writable with
  executable, adds the record through its one insert function, which
  refuses with `ERX_ESTALE` a memory object or a space that is closed
  ([Execution model and locking](#execution-model-and-locking)), and
  charges and backs the tables' part of the space's reserve, by the
  commit's rule, before the record is added. A JIT object belongs to the
  space whose thread
  created it, which must have been created with `ERX_SPACE_JIT`: the
  object records that space's object id at its creation and never changes
  it, and `erx_vm_map` maps the object into that space alone, refusing
  every other with `ERX_ERIGHTS`, whatever spaces the caller holds with
  `MAP`; there it may be mapped read-execute in one mapping and read-write
  in another. Device memory is never executable. Closing the capability
  leaves the mapping; deleting the object makes every later access to it
  fault ([Closing and deleting](#closing-and-deleting)).
* **Kernel-user pages.** Each thread's kernel-user page is mapped at an
  address the kernel picks below the placement base, in a record of kind
  `ERX_MAP_KERNEL` charged with the thread; no range call changes or
  removes it, and a range call that overlaps it fails with `ERX_EEXIST`.
* **Bounded range calls.** `erx_vm_commit`, `erx_vm_decommit` and
  `erx_space_protect` change records in place, a part at a time: each
  part acts on the range only as far as the end of the first record it
  meets, holes before it included, and edits at most three records in one
  logarithmic step, and a preemption point follows each part, so the range
  is consistent at every preemption point, which is all that another call or
  a fault in the space can observe. A commit's part is also at most 64 pages;
  a decommit's or a protect's spans the record it meets, so the work it
  implies beyond the records proceeds in smaller units of its own: translations
  a table at a time (**The edge rule** below), and a private object's released
  offsets as one page subtree that goes to the reaper whole.
  `erx_vm_release` takes any number of records out of the space at the
  cost of detaching one subtree, and then unlinks them from their objects
  a part at a time. Every range call holds its space's existence lock from
  its first part to its last, as Fiasco's unmap holds the task's, so a
  space's destroy waits for it and never tears down records that a call
  is still changing.
* **The edge rule** bounds the table work of every range call, and a
  table goes only with the promise that reserved it. In the tables that
  a range covers only partly, which lie at its two ends, a call edits
  entries one by one, at most 511 per table. A range here is a part's, for a
  call made of parts, since a call can stop at a mapping of an object further
  on. A table that a decommit's part, a release or a replacing reservation
  covers completely holds no promise once the records have moved: a decommit's
  part lies in one record of private memory, and the other two end every promise
  in their range. The call detaches it whole by clearing the one entry above it.
  An insert of any other kind detaches nothing, since its record takes over every
  promise in its range. Only an edge table, which a record outside
  the range may touch, is kept or detached by the records as they stand after
  the apply: it stays, empty or not, while a record that holds a promise
  touches its span, since its page is that record's promise, and it is detached
  once none does. **The table step** clears entries in place, one table at a
  time with a preemption point between tables, and detaches no table, since
  every promise stays. Two calls work this way: a protect that lowers a
  protection, and a deletion ([Closing and deleting](#closing-and-deleting)),
  whose deleted record keeps its promise until its range is released. A
  private object's page tree follows the same rule over the offsets the range
  maps. A decommit's part or a release therefore touches at most a few thousand
  entries however large or populated its range, with a preemption point between
  parts. Three costs grow past that, and each follows translations that faults
  in the space built, so none lets a call of one domain spend more than its
  target's own earlier work: the table steps of a protect and of a deletion, and,
  where the hardware keeps dirty bits, the
  read of a table detached whole that holds translations of a shared object's
  pages, entry by entry for their dirty state, a table at a time between
  preemption points, before it is freed (**Store tracking** below). After the
  TLB invalidation has completed, the detached tables, the released
  pages and the pooled pages of the promises that ended go to the
  released list, to wait out the grace period of K9, uncharged ([The
  reaper](#the-reaper)). Faults rebuild whatever was cleared, with the
  mapping's protection, from the space's pool.
* **The fault decision.** Every memory fault goes through one pure
  decision, `erx_fault_decide`, over what the fault path loads under its
  space's lock: the mapping that covers the address, with its
  kind and protection, the page's state, read under the mapping's
  object's lock, and the access (read, write or
  fetch). Whether the CPU reported a missing translation or a permission
  fault does not enter it, so a store to a page mapped read-only for copy
  on write or for store tracking takes the same path as a first touch.
  Every result resolves the fault from the object the mapping names or
  stops the thread; none sends a message, and none waits. The first row
  that holds decides:

  | The fault | Result |
  | --- | --- |
  | no mapping covers the address, or its protection does not allow the access | a fault record of kind `ERX_FAULT_MEMORY` |
  | the mapping is marked `ERX_MAP_DELETED` | a fault record of kind `ERX_FAULT_DELETED` |
  | a copy-on-write child | **copy at first touch**: `erx_cow_decide`, and `erx_cow_install` for a page the child does not own, read or write, from the child's pool; then **populate** with the child's own page (**The first-touch funnel** in [Copy-on-write children and copies of spaces](#copy-on-write-children-and-copies-of-spaces)) |
  | a write to a shared object's page that is populated and clean, where the architecture tracks stores by protection | **mark stored**: record the store in the object's page state and map the page writable (**Store tracking** below) |
  | any other page of any other mapping | **populate**: take any missing table from the space's pool; private memory takes a page from the same pool and fills it from its source or with zeros, a shared object's page comes from the object's own pool, zeros at first touch, and any other object maps its matching page; the translation comes from `erx_pte_make` |

  Once the result is applied the thread resumes where it faulted; nothing
  of the thread's runtime runs meanwhile, so a fault inside a runtime's
  scheduler or collector is harmless. The page a populate or a copy
  takes comes from its reserve's pool, through `erx_reserve_take` under
  the owner's lock, which zeroes it: a fault touches neither the page
  allocator nor a budget, waits for nothing and fails for nothing, since
  the pool holds a page for every promise not in use
  ([Budgets](#budgets), [The reaper](#the-reaper)). Committed memory
  therefore never faults for lack of memory, and no fault waits (K6).
  There is no pager: a page that a mapping reaches either comes from its
  object or the access ends the thread. The decision's exhaustive host
  model covers every mapping kind, page state and access.
* **One hold.** A fault holds its space's lock from the lookup of the
  mapping to the write of the translation, one bounded part, and
  selects and publishes under that one hold: the mapping it found, the
  object the mapping names and the page it chooses, from the object's
  pool or the space's, are the ones its translation names. Nothing it
  looked up can change meanwhile, since every change to the space's
  mapping records, every removal of a translation and every detachment
  of a mapping from its object takes that lock, and an object's pages
  are released only after every mapping of it is detached
  ([Closing and deleting](#closing-and-deleting)); so a deletion of the
  object or an unmap of the range either came before the fault's hold,
  and the fault finds no mapping, or a deleted one, and stops the
  thread, or comes after it, and removes the translation the fault
  wrote. The lock is a helping lock, taken before the lookup, so
  helping its holder, which passes preemption points, ends no
  protection the fault relies on ([Execution model and
  locking](#execution-model-and-locking)); the spinlocks the fault
  takes inside the hold, the object's lock for a page's state and a
  child's lock for a copy, come after the space's lock in the lock
  order and are released before the translation is written. Two
  faults at one address of one space serialise on the space's lock,
  and the second finds the translation written.
* **Store tracking.** `erx_mem_dirty(mem (SUPPLY), offset, npages)`
  reports, in the caller's UTCB, one bit for each page of the range that
  was stored to since the last report on it, or since the object was
  created, and marks those pages clean; a range is at most 64 pages for
  each message register, and the call refuses any object but a shared one
  with `ERX_ETYPE`. A session's mapper, which keeps `SUPPLY` and maps the
  object into its programs through capabilities with `READ`, `WRITE` and
  `MAP` alone, uses it to write back only the pages of a shared mapping
  of a file that a program stored to
  ([design-files.md](design-files.md#shared-mappings)). The kernel learns
  of stores in one of two ways, which the binding chooses by what the CPU
  has ([design-arch-aarch64.md](design-arch-aarch64.md#translation)):
  where the hardware manages a dirty bit in the translation entry, a
  clean page is mapped writable and clean and the hardware marks the
  entry on the first store; elsewhere a clean page is mapped read-only
  and the first store faults to **mark stored** above.

  A store is therefore held in one of two places: the object's per-page
  **stored mark**, which the fault sets, or the dirty bit of a live
  translation. Translations come and go, so the dirty bit is never
  dropped unread: every removal of a translation, whatever call or
  teardown makes it, goes through the invalidation plan of K9 before
  anything it covered is freed, and that plan's last step, once the
  invalidations have completed and no CPU can mark the entry any more,
  passes each cleared entry of a shared object's page, those of a table
  detached whole included, to `erx_vm_fold`, which sets the page's stored
  mark under the object's lock when the entry was dirty. A report reads,
  through the object's reverse map, the union of the stored marks and the
  dirty bits of the live translations, clears both for each page it
  reports, removing the write permission or the mark from each such
  translation, and waits until that invalidation has completed (K9)
  before it returns. So a store that comes after a report is reported by
  the next one, a store whose translation's removal completed before a
  report began is reported by that report, and none is lost. No
  user-mode party takes part, and no store waits for one.
* **TLB.** User mappings are non-global and tagged with their space's
  ASID; kernel mappings are global. Every change follows the
  architecture's rules for translation-table maintenance, which the
  binding states
  ([design-arch-aarch64.md](design-arch-aarch64.md#tlb-maintenance)): the
  entry is written and made visible to table walks, the cached entries it
  makes stale are dropped from every CPU's TLB, the kernel waits for the
  invalidation to complete, and the current CPU synchronises where it must
  see the change. An entry that maps a page is replaced by one that maps
  another only through an invalid entry and a completed invalidation. No
  page or table that a removed entry covered is freed or reused before
  that invalidation completes (K9).
* **What is invalidated follows from what was removed**, never from a
  page count alone. A cleared entry that maps a page makes that page's
  cached translation stale. A cleared entry that points to a table,
  whether the table is detached whole or freed because a partial range
  left it empty, makes stale every translation cached through it and the
  CPU's cached copy of the entry itself, which a CPU may keep in a walk
  cache and follow into the freed table long after: the binding drops
  those with an invalidation that reaches every level of the walk, over
  the table's span, or for the whole ASID. A plan whose invalidations by
  address would exceed 64 invalidates the whole ASID instead. Every range
  call's plan lists each entry it clears with its kind, page or table,
  and `erx_tlb_plan`, a pure function, derives the invalidations from that
  list; a host test checks, over random ranges, table shapes and
  populations, that every cleared table entry is covered by an
  every-level invalidation of its span or of the whole ASID and every
  cleared page entry by one of its page, its table's span or the ASID,
  and that nothing a cleared entry covered is freed before the plan's
  invalidations complete. DMA windows follow the same rule with the
  IOMMU's invalidations ([DMA and the IOMMU](#dma-and-the-iommu)).
* **ASIDs** carry a generation and are allocated as Linux allocates them;
  their width comes from the binding. A space gets an ASID when it first
  runs. When the values run out, the allocator advances the generation,
  keeps for each CPU the ASID it is running, has each CPU invalidate its
  TLB before it next switches spaces, and gives every other space a fresh
  value when it next runs. A dead space's ASID is invalidated before its
  tables are freed, and only then retired. ASID 0 is reserved for the
  empty user table installed while the idle thread runs. A space takes an
  ASID only once it runs, and a domain that creates and ends sub-spaces
  quickly can force rollovers, each an invalidation of every CPU's TLB;
  [Security](#security) bounds the rate.
* **Caches and code.** Where the architecture lets user mode read the
  cache geometry and clean and invalidate caches by address, as a JIT
  needs, the binding allows it
  ([design-arch-aarch64.md](design-arch-aarch64.md#cache-maintenance)); a
  runtime that writes code makes it coherent itself and has every executor
  that may run it synchronise its instruction stream, which ERTS's code
  barrier does ([design-runtime.md](design-runtime.md#beamasm)). That is a
  JIT's **publication**, an explicit step of the runtime: code written
  through a JIT object's writable mapping becomes reachable through the
  executable one only after it, and what the kernel guarantees is that no
  other space and no device holds an alias of those pages (K8). When the
  kernel fills a page of an object whose ceiling includes execute, it
  makes the page coherent for instruction fetch before any mapping reaches
  it. The boot image is made coherent for instruction fetch once, at boot.

The physical page allocator is a buddy allocator over 4 KiB pages, which
hands out single pages and nothing larger, with an array of page records
(reference count, flags, owner, and the link that chains a page on a
reserve's pool or on the released list) in the direct map; a translation
table's record counts its valid entries. Kernel records come from caches
kept per budget ([Budgets](#budgets)).

### Copy-on-write children and copies of spaces

These mechanisms give programs shared code pages, private copies of
data and `fork` ([design-programs.md](design-programs.md#the-second-tier)),
and they are deliberately small: a child is one level deep, every object
is reserved in full at creation, a child's mappings reach only pages the
child owns, and nothing is evicted or discarded.

**Immutable objects.** Three kinds of object never change once in use: a
slice of the boot image (K16), a paged object once sealed, and a shared
object once sealed. Besides JIT objects in JIT spaces, only immutable
objects are mapped executable, and only immutable objects parent
copy-on-write children, so no page a program executes or copies from
changes under it. The whole boot image, which never changes either, is
not among them: its empty ceiling admits no mapping, and `erx_mem_child`
refuses it as it refuses every parent outside the three (K16).

**Paged objects.** A paged object holds a file's bytes for the programs
that run or map it: it is filled whole by its supplier and then sealed,
and no fault on it ever waits, since it is mapped only once sealed. The
system domain creates it with `erx_mem_create_paged(budget, size, flags)`,
which needs `ALLOC` on the budget and reserves, charges and backs the
object's whole size at creation, in parts of at most 64 pages: no
overcommit, no eviction, no discardable page.
With `ERX_MEM_CODE`, which needs `CODE` on the budget and which only the
system domain's budget capabilities carry ([Rights](#rights)), the object
has an execute ceiling; without it, it is never executable. The budget is
that of the session or domain the object is for.

While it fills, a holder of `SUPPLY`, its **supplier**, copies bytes into
it from a staging window of its own with `erx_mem_supply(object (SUPPLY),
offset, src (READ), src_offset, len)`, through the kernel's own mappings
of both objects, in parts of at most 64 pages with a preemption point
after each ([Arguments and results](#arguments-and-results)). The call
fills only pages not yet supplied, so a supply that fails part way, as it
does with `ERX_ESTALE` when its source is deleted, is repeated safely.
`erx_mem_seal(object (SUPPLY))` ends the filling, and no call changes a
page after it. `erx_vm_map` refuses a paged object not yet sealed with
`ERX_EBUSY`, so no mapping sees a page change: every page was supplied or
reads as zeros. A supplier holds `SUPPLY`, and may also hold `READ` and
`MAP`, with which it maps the object like any holder once it is sealed.

**Copy-on-write children.**
`erx_mem_child(parent (READ, CHILD), budget (ALLOC), offset, size)` makes
a child of a range of an immutable object; any other parent is refused
with `ERX_ETYPE`. It is reserved, charged and backed at its full size,
in parts of at most 64 pages, under a construction record of its own,
and published, to its budget, its parent and the caller's table, only
once backed in full (**Construction**,
[The reaper](#the-reaper)), so a copy on write takes a page of the
child's pool and never fails or waits at a random instruction; failures
happen at calls, as for every other kind. The child is a new
object with a slot list of its own, attached to its parent object on the
parent's `att_children` rather than to the capability it was made
through, and it dies with the parent: destroying the parent deletes every
child ([Closing and deleting](#closing-and-deleting)). The child may be
charged to another budget than the parent, which is how a session's
program reads a file server's object: the program's private copies are
the session's, and the parent stays the server's. It is one level deep: a child carries
no `CHILD` right and is not immutable, so a child of a child is refused
with `ERX_ETYPE` and no tree of hidden nodes exists. Its ceiling is
read-write, never execute, so no code is copied into anything a program
can write. A child keeps a tree of the pages it owns; a page it does not
own reads as its parent's through a memory window ([Arguments and
results](#arguments-and-results)), and is copied into the child before
any mapping of the child reaches it.

**The first-touch funnel.** A child's mapping is populated only with
pages the child owns: no translation in any space names a page of the
parent through the child. The fault decision sends every fault in a
child's mapping, a read or a write, to one pure decision and one
installation:

```c
typedef enum erx_cow_action {
	ERX_COW_MAP_OWN,	/* populate with the child's own page, with the
				 * mapping's protection */
	ERX_COW_COPY		/* copy the parent's page into a page of the child's
				 * reserve and record it as owned, then populate */
} erx_cow_action_t;

/* The decision for one fault on one page of a child. */
erx_cow_action_t	erx_cow_decide(bool owned);

/* Applies ERX_COW_COPY under the child's lock, from the child's pool; the
 * only code that makes a child's page its own. A fault calls it inside
 * the hold of its space's lock under which it writes the translation. */
erx_status_t	erx_cow_install(erx_memobj_t *child, erx_npages_t page);
```

`erx_cow_decide` returns `MAP_OWN` for an owned page and `COPY` for any
access to a page the child does not own. `erx_cow_install` runs whole
under the child's lock, a spinlock: it takes a page from the child's
pool through `erx_reserve_take`, which never allocates and never waits,
copies the parent's page into it through the direct map, as a memory
window reads the parent, and records it as owned. It touches no
translation table and walks no mapping of the child, so it does one
page's work however many addresses and spaces map the child. A fault
calls it inside the one hold of its space's lock under which it looked
the mapping up and writes the translation (**One hold**, [Virtual
memory](#virtual-memory)), the child's lock inside the space's as the
lock order has them; so the page it records as owned is the page the
translation names, and the child is alive and holds that page from the
lookup to the write, since no detachment of the mapping and no release
of the child's pages can pass the space's lock meanwhile. Two faults on
one page of the child, in one space or two, serialise on the child's
lock, and the second finds the page owned and populates with it.
Every user translation is built by one function, `erx_pte_make`, which
grants write only for a page that its mapping's object owns exclusively
(a private page, a shared object's page, a child's own page). The kernel
itself never stores through a user translation (K7): its one write into
an object's pages on a caller's behalf, a window write ([Arguments and
results](#arguments-and-results)), goes through `erx_cow_install` for
any page of a child that the child does not own before it stores to the
page through the direct map. Together these close the class of Linux's
Dirty COW (CVE-2016-5195), in which a write meant for a private copy
reached the shared page by a path that skipped the copy: no page shared
by copy-on-write is ever mapped through a child, by any translation, and
the only step that makes a page of a child reachable, by a program or by
the kernel, first makes it the child's own. What copying at the first
read costs is one page copy for each page a child reads and never
writes, into pages the child already holds, since it is backed in full
at creation; what it buys is a fault that touches one object and one
translation, with no walk of the child's mappings ([Alternatives
considered](#alternatives-considered)).

**DMA takes only owned pages.** A DMA window maps only pages its object
owns exclusively: a shared or contiguous object's pages, or a child's own
pages. `erx_dma_map` refuses an immutable object, a paged object, and a
child range with a page the child does not own, with `ERX_EBUSY`, and a
JIT object with `ERX_ETYPE`, so no device writes code (K8);
`erx_mem_own(child (WRITE), offset, size)` first copies every page of the
range the child does not own into the child, from its reserve, in parts of
at most 64 pages. No device ever writes a page that a parent or another
child shares.

**Sealing.** `erx_mem_seal`, with `SUPPLY`, makes an object immutable for
good: a paged object, which ends its filling, and a shared object. One
count makes that hold whatever path a write would take.
Every path that can write an object's pages counts itself among the
object's **writers**, under the object's lock and after checking that
the object is not sealed: a CPU or DMA mapping whose ceiling allows
writing, from its creation until its removal, and a part of a window
write, `erx_mem_copy` into the object included, or of `erx_mem_supply`
while it runs. The kernel writes an object's pages through no other path
(K7). `erx_mem_seal` seals the object under the same lock only while it
has no writer, and fails with `ERX_EBUSY` otherwise. So once a seal
succeeds no writer is left and none can start: a window write and
`erx_mem_supply` into a sealed object fail with `ERX_ERIGHTS`, a new
mapping of it gets a ceiling
without write (K4), and no device can change it either. A sealed shared
object may parent children, which are then its snapshots.

**Copying a space.** `erx_space_copy(from (MAP, STOP), to (MAP, CAPS),
ticket)` makes `to`, a space its creator has just created for a forked
child, a copy of `from`, under the hold on `from` that the ticket names.
The call is a sub-space creator's: a session holds `MAP`
and `STOP` on the parent program's space and `MAP` and `CAPS` on the
child's, since both are its sub-spaces, and no other space holds them
(K17). It refuses the caller's own space as either, and a ticket not
held, with `ERX_EINVAL`, since it holds `from` and fills `to` from
nothing. It needs `from` quiesced, its `quiesced` mark set (**Pausing a
space**, [Threads and faults](#threads-and-faults)), and refuses one
that is not with `ERX_EBUSY`: the caller pauses `from`, quiesces it
with `erx_space_quiesce` under that hold, copies under it, and resumes
the hold, so the one wait of a `fork` is the quiesce, a wait that holds
nothing (K33), and the copy itself waits for nothing and holds its work
on its own frames from its first part to its last; resuming the hold
ends whichever of the two is under way, whatever other holds the
session keeps on `from`. It needs `to` empty, with no mapping and no
capability, and refuses one that is not with `ERX_EEXIST`. The copy
never replaces what it finds, so if `to`'s creator adds a mapping or a
capability while the copy runs, where the copy would place its own, the
copy ends with `ERX_EEXIST` as well; a session adds nothing to a child
until its copy has ended
([design-programs.md](design-programs.md#the-second-tier)). The dispatch
looks `from` and `to` up and holds no lock, since the ABI file marks neither
`exists`; the handler's first act, with no preemption point after those
lookups, takes both spaces' existence locks with
`erx_object_lock_existence2`, in address order, as Fiasco's map holds
both tasks' (`task.cpp`), so a copy of a space onto itself is `ERX_EINVAL`,
and the handler holds them to its end and releases them itself; beside them it
holds each fresh child's construction lock while it makes that child,
and the child's own across the inserts that publish it (**Copying**
below, **Construction** in [The reaper](#the-reaper)).

**Why the copy reads one moment.** `from`'s private memory and mapping
records change only through calls and faults that its threads make from
user mode, which the pause rules out, and through calls of other
parties, which the rule after the table below covers. A thread of `from`
woken from a wait while the space is paused only completes the call it
waited in, which writes the thread's registers and UTCB and nothing else
(K33), and the copy never reads those; the thread then waits at the
boundary, so the mark holds until the pause is lifted. So once the mark
is set the copy reads one state of `from`'s memory and records, as its
own threads left them, without any other party having to stop them.

**Copying.** It copies in parts of at most 64 pages, with a preemption
point after each, and charges `to`'s budget for each thing when it
makes it, through the one charging funnel (K3): each committed private
page it copies and the translation tables with their pages, backed into
`to`'s reserve under `to`'s existence lock, which the copy holds; and
each fresh copy-on-write child at its full size, as creating a child
reserves it (K23), backed under a construction record of its own, whose
lock the copy holds beside `from`'s and `to`'s, and then published to
`to`'s budget, its parent object and `to`'s table (**Construction**,
[The reaper](#the-reaper)). A charge the budget refuses ends the
copy with `ERX_ENOMEM`, leaving `to` partly filled for its creator to
destroy, as a session does at once, so a `fork` fails at the call and
never later at a write. Between parts, a child's backing parts
included, it checks that its hold is still held, the slot its ticket
names holding that ticket, and `from` still marked, ending with
`ERX_EBUSY` if its caller resumed the hold, and whether either space
has stopped or been closed, which a backing reads in the existence
locks its thread holds; if one has, the copy makes nothing more,
releases `from`'s and `to`'s existence locks within that part, and
ends with `ERX_EDEAD`, so a destroy of either waits for at most one
part of at most 64 pages. Noticing the end and finishing the cleanup
are two different bounds: a child half made is torn down by the copy
before it returns, as any construction that fails is, under the
child's construction lock alone, in parts bounded by the pages that
were backed, and nothing of a child attaches to `from` or `to` until
it is published, so that teardown keeps neither space's destroy
waiting (**Construction**, [The reaper](#the-reaper)).

**Who pays, and how a copy ends.** A copy is a bounded transaction of the
thread that calls it, funded by whoever asks for it:

* **Its CPU time** is that thread's, charged to the thread's own group as
  every call's is
  ([design-scheduler.md](design-scheduler.md#charging-and-quota)), and
  none of it to `to`'s group, which may have no grant yet. **What it
  creates** is charged to `to`'s budget, so the child pays for its own
  memory.
* **It never waits.** The one wait of a `fork` is its caller's
  `erx_space_quiesce`, which depends only on `from`'s own threads
  finishing calls they started, on their own groups' time (**Pausing a
  space**, [Threads and faults](#threads-and-faults)); the copying
  depends only on the caller's time and on `to`'s budget, which refuses
  a charge at once rather than waiting.
* **It is bounded.** A copy runs on one thread, so the copies under way
  never outnumber the threads that make them, and its caller bounds those
  ([design-programs.md](design-programs.md#the-second-tier)).
* **It always ends, and its caller learns how.** A stop or a close of
  `to`, which `to`'s creator can make at any time, and a stop or a close
  of `from` end the copying at the next part, and the copy returns
  `ERX_EDEAD` to its own thread, which goes on to report the outcome as
  it reports a success; the resume of the hold the copy runs under ends
  it at the next part with `ERX_EBUSY`, whatever other holds remain, as
  it ends a quiesce (**Pausing a space**, [Threads and
  faults](#threads-and-faults)). So a creator
  that gives up a `fork` resumes `from`, at either phase, or stops
  `to`, and then hears the end from its copier, as a session does
  ([design-programs.md](design-programs.md#the-second-tier)); a `CONTROL`
  stop of the copier, which would leave it stopped at its return to user
  mode with the outcome in its registers and nothing reported, is not how
  a copy is abandoned. Every ending releases the two spaces' locks
  before it tears down a child it was making, and allocates nothing;
  the pause of `from` is its caller's to lift, as every pause
  is, and `to`'s destroy, which runs on the time of whoever destroys it
  and allocates nothing either, takes back whatever the copy made.

Parties other than `from`'s threads may still change what `from` holds
while the copy runs: a reply fills a slot that a waiting receive reserved,
the space's creator gives or closes a capability or changes a range,
another holder writes a memory object that `from` shares. Each such change
lands before or after the copy reaches that slot or page, so the child
sees it whole or not at all; a capability that reaches the child this way
is one that no thread of the child knows of, like a descriptor that
another thread received just before a POSIX `fork`. The copy decides every
mapping by its object's kind, in one table, whose default is to leave a
thing out:

| What `from` maps | What `to` gets at the same address |
| --- | --- |
| private memory | fresh private memory, its committed ranges reserved, charged and backed as the original's are, each committed page copied, each page still mapped once (K5) |
| a copy-on-write child | one fresh child of the same parent for each original, its own pages copied from the original's, so children stay one level deep and aliases within the child stay aliases |
| an immutable object: a slice of the boot image, a sealed paged object, a sealed shared object | the same object, with the same protection and ceiling, in a mapping of its own on the object's reverse map, so code the parent mapped stays executable and the child executes nothing the parent had not mapped |
| a shared object its creator made with `ERX_MEM_INHERIT` | the same object, so `MAP_SHARED` memory, anonymous or a file's, stays shared, as POSIX requires; `liberx` and the session's mappers set the flag on that memory alone |
| any other shared object (a lane's ring or reader page, a channel's pages, a pipe's ring, a crash area, a boot information page, memory another space passed in), physical memory (device registers, a group's shared areas, the time page), contiguous memory, a thread's kernel-user page | nothing: the session maps the child's own channel and pipe rings once the copy has ended, and the child's `liberx` maps its own group's areas and the time page ([design-programs.md](design-programs.md#the-second-tier)) |
| a JIT object | nothing: the call fails with `ERX_ENOTSUP` |
| a mapping marked `ERX_MAP_DELETED`, or one whose object is deleted while the copy runs | a deleted mapping, since the object's reverse map takes nothing once the object is closed (K26) |

Capabilities follow the same table. Into `to`'s table, which must still be
empty, at the same values, a capability goes only when it carries `DUP`,
memory included: a capability to a memory object goes when that object's
mappings would, naming the fresh child for a copy-on-write child, and a
capability of another type goes when its type has a pass set, with its
rights intersected with that set (K24). `GIVE` is not needed: a file
object that a program may keep but not pass on is copied into the child,
which is a copy of the same program and still lacks `GIVE` there. So a
fork never copies a budget, a space, a thread, a group, a JIT object or
a thread's signal IRQ object, which `liberx` creates without `DUP`, and
the child holds no sub-space of its parent's. A capability
whose object is deleted while the copy runs is left out, and a slot
reserved for a receive of `from`'s is copied as free. `to`'s table is
grown to `from`'s capacity, within `to`'s capability limit, which its
creator sets at least to `from`'s, a smaller one failing the copy with
`ERX_ELIMIT`; a copied slot takes `from`'s generation, every other slot
starts at a generation one past the same slot's in `from`, and a slot that
is retired in `from`, or whose next generation would reach 2^40 - 1,
starts retired, as a slot that reaches it is retired instead of freed, so
a capability value the child inherited in its memory names in the child
the same object or nothing, never another (K1).

It copies `from`'s per-space pointer-signing keys, where the architecture
has them, since the copied stacks hold pointers signed with them. A kind
of memory reaches a forked child only through a row of the table, so no
flag has to be remembered by the creator of memory a child must not share,
and a kind the table forgets fails loudly in the child, as a missing
mapping, rather than sharing what it should not.

A program's image is replaced, for `exec`, by a fresh sub-space that its
session builds while the old one runs and fills once the old one has
stopped ([design-programs.md](design-programs.md#the-second-tier)), so the
kernel has no call that resets a space; whether the program's children
run on across its `exec` follows from where the session hung them
([Creating spaces](#creating-spaces)).

**Size.** These additions are an estimated 1,800 to 2,300 lines of C17:
paged objects and sealing about 300, children with the funnel,
`erx_mem_own` and the DMA check about 1,000, copying and pausing a space
about 600, and store tracking with `erx_mem_dirty` about 200 (an
estimate summed from those parts). With them the kernel's memory code is
an estimated 6,500 to 7,500 lines, against the 40,774 lines of Zircon's
virtual memory at release f32
([research](research-kernel-bases.md#zircon)), much of which serves what
erXos leaves out: trees of hidden clone nodes, the attribution of pages
along chains of clones, eviction, discardable memory and user-mode
pagers.

**The stopgap.** The modified Fiasco implements paged objects supplied
whole and sealed, which hold the code and files programs run and map, and
none of the rest: copy-on-write children, store tracking and copies of
spaces are erXos's kernel's alone, since Fiasco's memory model of mapping
databases and user-level pagers has nothing to build them on. The
personality's second tier, which needs them, runs on erXos's kernel
([plan.md](plan.md#track-q-the-second-tier),
[The current implementation](#the-current-implementation-the-modified-fiasco)).

### Arguments and results

Every argument of a kernel call comes from one of three places, and the
ABI file's grammar has no fourth and no pointer type: a register, a field
of the caller's UTCB, or a memory window. So the kernel never loads or
stores through a user address (K7), and no call can make it touch kernel
memory a domain names, or fault in kernel mode on memory a domain
unmapped:

```c
typedef struct erx_window {
	erx_memobj_t	*obj;		/* the object a capability named */
	uint64_t	 offset;	/* byte offset, checked against the size */
	uint64_t	 length;	/* bytes, at most the call's declared maximum */
} erx_window_t;

/* Copy between a window and kernel memory through the kernel's own
 * mapping of the object's pages, in parts of at most 64 pages with a
 * preemption point after each. Each part checks that the object is not
 * destroyed, and fails with ERX_ESTALE if it is; a write counts itself
 * among the object's writers and takes a copy-on-write child's page
 * through erx_cow_install first. Neither interprets the bytes. */
erx_status_t	erx_window_read(const erx_window_t *w, uint64_t at,
		    void *dst, size_t len);
erx_status_t	erx_window_write(const erx_window_t *w, uint64_t at,
		    const void *src, size_t len);
```

* **Registers** carry capabilities, integers, flags, deadlines and
  page-aligned addresses, which the decoder checks by type ([System-call
  dispatch](#system-call-dispatch)).
* **The UTCB** carries what does not fit: a message's words and items, a
  new thread's starting registers, a register set to read or write, the
  bytes `erx_entropy_add` credits and `erx_debug_log` logs. The UTCB lies
  in the thread's kernel-user page, kernel memory that the kernel reaches
  through its own mapping and that never faults. The ABI file declares
  each layout, and the generator refuses one longer than the 63 message
  words. The decoder loads each field once through `erx_shared_load_*`
  into kernel memory and decodes it there, so user mode rewriting the
  UTCB meanwhile changes nothing the call decides on.
* **A memory window** carries bytes beyond the UTCB: a capability to a
  memory object, with `READ` for a window the kernel reads and `WRITE`
  for one it writes, an offset and a length. The decoder looks the
  capability up and checks the offset and length against the object's
  size with checked arithmetic, and the length against the call's
  declared maximum, which the generator keeps at or below
  `ERX_COPY_MAX`; the handler takes a counted reference before its first
  preemption point and drops it at completion. A window refuses physical
  memory with device attributes and JIT objects with `ERX_ETYPE`, since a
  kernel access to a device whose link has dropped would abort in kernel
  mode ([Interrupts, time and entropy](#interrupts-time-and-entropy)) and
  the kernel writes no code. A window reads a child's page that the
  child does not own from the child's parent, whose pages never change,
  as a mapping of the child does ([Copy-on-write children and copies of
  spaces](#copy-on-write-children-and-copies-of-spaces)); only a shared
  object's page not yet populated, and a paged object's page never
  supplied, reads as zeros. A write populates a shared object's page from
  the object's own reserve, and makes a child's page its own through
  `erx_cow_install` from the child's reserve, so a window access never
  waits and never fails for lack of memory. The calls that take a window
  are `erx_mem_copy`, `erx_mem_supply`, `erx_object_info` and the readers
  of the log and the trace rings.

**Results.** A call returns a status and up to two result registers; what
does not fit goes into the caller's UTCB, as Fiasco returns an IPC's words
and items: a message and its items, the values `erx_cap_pass` gives in its
target table, the bits of `erx_mem_dirty`, a register set, the bytes of
`erx_entropy_read`. A call
writes a window only when it changes nothing but that window's bytes and
the caller's UTCB and registers, as `erx_mem_copy`, `erx_object_info` and
the log and trace readers do; the generator refuses a written window on
any other call ([The ABI file](#the-abi-file)). So a window that fails
part way, with `ERX_ESTALE` because its object was deleted, leaves no
effect that repeating the call would repeat.

**No call that may wait takes a window.** A window holds a counted
reference only for a bounded stretch of its caller's time, and a call's
part after its wait then writes nothing but the caller's registers and
UTCB, which copying a space relies on ([Copy-on-write children and
copies of spaces](#copy-on-write-children-and-copies-of-spaces)). The
generator refuses a window on a call that may wait.

**Addresses as names.** A user address appears in a call only as a name.
A page-aligned address of a range call or a mapping becomes an
`erx_uvpn_t`, which only the space's mapping records resolve. A umtx
word's address becomes an `erx_uword_t`, which the architecture layer's
`erx_uword_load` resolves by walking the caller's translation tables in
kernel memory and refusing a page the direct map does not cover, before
one atomic load through the direct map ([Umtx](#umtx)); this is the one
call that names memory by address, since private memory, where lock
words live, has no capability (K5). Its `ERX_EFAULT`, for an address no
valid user-readable entry maps or whose page lies outside the direct
map, is the only use of that status. Since no kernel access goes through
a user translation, the kernel needs no user-copy loops, no
exception-fixup table and no switch that opens user memory to kernel
mode, and a synchronous exception taken in kernel mode is a kernel bug,
which panics ([Console, log and panic](#console-log-and-panic)).

**The kernel's shared areas.** Each thread's kernel-user page, with its
UTCB and vCPU state area, a group's control and status areas and the time
page are kernel memory mapped into a space. The kernel reads the
user-writable ones only through `erx_shared_load_u8`,
`erx_shared_load_u16`, `erx_shared_load_u32` and `erx_shared_load_u64`,
one atomic load per field per decision, and validates what it loaded: a
message's tag, items and buffer descriptor are loaded once at the
dispatch, and a resumed frame is loaded field by field into the thread's
record before it is checked. It moves message words from one UTCB to
another only through `erx_msg_copy`, a bulk copy that interprets nothing,
so a sender that rewrites its words during the copy changes only what the
receiver reads as words. It writes a user-writable area through
`erx_shared_store_*`, and the read-only areas with release stores
([design-scheduler.md](design-scheduler.md#urgency-resolution)).
These accessors, `erx_msg_copy` and the window functions are the only
code that touches memory user mode can write, a build check ([Chokepoint
checks](#chokepoint-checks)).

### Interrupts, time and entropy

**The interrupt controller.** The kernel owns the interrupt controller,
which the binding programs so that one operation ends an interrupt
([design-arch-aarch64.md](design-arch-aarch64.md#interrupt-controller)).
It uses:

* three inter-processor interrupts, `ERX_IPI_REQUEST` (a CPU has
  requests), `ERX_IPI_SYNC` (a synchronisation round) and `ERX_IPI_STOP`
  (panic), and no others;
* one per-CPU line for the kernel's timer, programmed one-shot from each
  CPU's timer wheel;
* the lines of the kernel's own devices (the IOMMU's event queue and the
  others), which it handles itself; and every other line,
  which stays masked until an IRQ object is created for it and its driver
  acknowledges it ([IRQ objects](#irq-objects)).

An interrupt handler runs with interrupts masked on the kernel stack of
the thread it interrupted, does bounded work and makes no indirect call.
For a line with an IRQ object it ends the interrupt at the controller and
applies the result of `erx_irq_step` for the event "fire": it masks the
line where the object's state requires and delivers to the object's
target. Only `erx_irq_ack` and the taking of a delivery unmask a line, and
only while no delivery of it waits or is owed, so a device cannot
interrupt faster than its driver takes or acknowledges its interrupts
([IRQ objects](#irq-objects)).

**MSIs.** A PCIe function signals an MSI by a write to the platform's
**MSI frame**, which raises one of the frame's interrupt lines
([design-platforms.md](design-platforms.md#msi-frames) names each
platform's frame and its range); `erx_irq_create` with `ERX_IRQ_MSI`
allocates one and returns the doorbell address and the value the PCIe
enumerator programs into the function ([IRQ objects](#irq-objects)). The
same frame and path serve TCG and HVF. The frame does not identify the
writer, so a device that can write it can raise any of its lines, a
residual that [Security](#security) records.

**Asynchronous errors.** An architecture may report the error of an
earlier access asynchronously, after the instruction that made it. The
kernel contains each such error at the narrowest boundary the hardware
identifies, claims no attribution it does not know, and panics only when
the architecture reports that no boundary holds. The architecture layer
keeps these errors masked in kernel mode except in short windows that its
handler recognises by address, the technique of KVM's exit path
([design-arch-aarch64.md](design-arch-aarch64.md#asynchronous-errors)):

* **In user mode** they are unmasked; one taken there is presumed to
  come from the running thread's accesses.
* **The exit window.** Every exit from user mode waits for the accesses
  already made to complete and checks for a pending error; if one is
  pending, it unmasks such errors for one instruction, and the error is
  presumed to come from the exiting thread's accesses.
* **The device window.** After the kernel touches its own device
  registers, and before it next enters user mode, it does the same in its
  own window, where an error is presumed to come from its own device.

`erx_async_error_classify` then decides, from the severity the
architecture reports and from the platform's error records, where it has
them:

| What the hardware reports | What the kernel does |
| --- | --- |
| the error was corrected, or has not yet been consumed | logs it, and stops nothing |
| the platform's error records name the device or the PCIe segment it came from | quarantines that device's window, as for a device that faults through the IOMMU, logs the error with its source and tells the device service, which resets the device or the segment ([design-platforms.md](design-platforms.md#dma)); no thread is stopped for it |
| a failed access whose effects the architecture reports contained, or a processor that reports no severity, with no record naming the source | stops the thread that the window or user mode presumes with a fault record of kind `async_error`, or logs an error of the kernel's own device |
| an error the architecture reports as uncontainable, or one that leaves the processor's state unrecoverable | panics |

Attribution is exact for errors of accesses that complete before that
wait does. A posted write, such as a PCIe memory write, can report its
error after the window that would have attributed it, and without error
records the kernel cannot tell such an error from the running thread's
own, so a record of kind `async_error` states a presumption, and the
inspector shows it as one. The presumption that names the wrong thread,
and the panic, are the security residual that
[design.md](design.md#residual-risks) records; each platform's contract
says which severity reports and error records it has
([design-platforms.md](design-platforms.md#dma)).

**Time.** The monotonic clock is the architecture's counter, converted to
nanoseconds with a multiplier and shift computed at boot from its frequency
(62.5 MHz under TCG, 24 MHz under HVF,
[measured](research-baselines.md#accelerator-capabilities)), with the
product taken in 128 bits so it never overflows. The binding lets user mode
read the counter and keeps every other user-mode timer access trapped
([design-arch-aarch64.md](design-arch-aarch64.md#timer)). Wall-clock time is
the real-time clock's reading at boot plus monotonic time since; the system
domain corrects it with `erx_time_set_wall`, which needs the `WRITE` right
on the time page. The **time page** is one read-only page mapped into every
domain that asks for it:

```c
typedef struct erx_time_page {
	_Atomic uint64_t seq;		/* monotonic; odd while being written */
	uint32_t	 version;	/* 1 */
	uint64_t	 counter_hz;	/* the counter's frequency */
	_Atomic uint64_t mult;		/* ns = (counter * mult) >> shift */
	uint32_t	 shift;
	uint32_t	 reserved;	/* zero */
	_Atomic int64_t	 wall_offset_ns; /* wall time minus monotonic time */
} erx_time_page_t;
```

A reader loops while `seq` is odd or changes across its reads, so a runtime
reads time without a kernel call and agrees with the kernel to the
nanosecond. The fixed frequency, version and shift are initialized before
publication; every mutable field uses the generated atomic accessors.
On sequence exhaustion wall-clock updates return `ERX_ELIMIT`, and readers
report the wall-clock conversion unavailable rather than retrying a
terminal count forever; monotonic time remains available from the fixed
counter conversion. The page's sequence is never reset during a boot.

**Entropy.** One ChaCha20 generator (RFC 8439), under a leaf lock:

* **State.** The generator's state is one 256-bit key, used with the
  zero nonce; every request and every mix spends the key once and leaves
  a new one, so no key makes two streams. The generator becomes ready
  when its first seed source is mixed into the all-zero key, and refuses
  reads and mixes until then, so no output comes from a key nobody
  seeded; the other seed sources below are mixed in after it. A mix
  takes the BLAKE3 digest of its bytes, computed before the lock is
  taken, so the lock is held for one ChaCha20 block whatever length a
  domain mixes. A digest takes at most one BLAKE3 chunk, 1024 bytes, and
  refuses more, and a refused digest keys nothing. One chunk has no
  chaining values to keep, so the hash's
  state, 112 bytes, and the kernel's copy of the bytes from the UTCB, at
  most 504, live on the kernel stack and the call allocates nothing; the
  hash erases its state and the call erases the copy before it returns.
  The working words ChaCha20 and BLAKE3 leave on the kernel stack are
  overwritten before each call returns: a read, a mix and a digest each
  burn one frame of 976 bytes, within the proof's 1024-byte frame cap,
  which the stack proof's run test holds deeper than a hash at each
  level it reads. The registers the calls may change are not
  erased; a return to user mode restores or clears them. Each chain stays
  within the 2048 bytes the proof allows the cores on the 8 KiB kernel
  stack. ChaCha20 is FreeBSD's and BLAKE3
  its authors', imported as erXos's code into `kernel/crypto/`
  ([design.md](design.md#dependencies)); the generator around them is
  the C17 core `kernel/core/rng.c`.
* **Seed.** At boot, `/chosen/rng-seed`, `/chosen/kaslr-seed`, 32 bytes
  from the board's random generator where the platform layer drives one
  ([design-platforms.md](design-platforms.md#entropy-sources)), for which
  it waits at most 100 ms, and counter jitter. Each source is mixed on
  its own and hashes within one chunk: `rng-seed` is 32 bytes under QEMU,
  `kaslr-seed` a 64-bit value, the board generator's read 32 bytes and
  the jitter at most a chunk of samples; a firmware's longer `rng-seed`
  is mixed one chunk at a time. Neither accelerator offers
  the architecture's random-number instruction
  ([measured](research-baselines.md#accelerator-capabilities)).
* **Forward secrecy.** After each request the generator replaces its key
  with output it never returns: the first 32 bytes of block 0 become the
  next key and the request's bytes start at block 1, so a compromise of
  its state reveals nothing it produced before.
* **Uses.** `erx_entropy_read` (at most 256 bytes per call, any thread),
  the per-boot stack-protector value, and every space's
  pointer-signing keys and placement base.
* **Mixing.** Any holder of a resource with `CARVE` may mix bytes in:
  the key becomes 32 bytes of the generator's own output, the first 32
  bytes of block 0, XORed with the BLAKE3 digest of the bytes, so whoever
  does not know the key cannot choose or weaken the next one.

Its quality:

| Quality | When | Then |
| --- | --- | --- |
| `good` | the boot seed came from `rng-seed` or the board's generator, or a holder of `ENTROPY` on the root resource has passed `ERX_ENTROPY_CREDIT` to `erx_entropy_add` with bytes from a source its configuration trusts | normal operation |
| `weak` | neither | the banner says so; a release build stops the boot, because every space's keys and placement would come from a weak seed, and a development build continues |
| `fixed` | deterministic mode, which release builds refuse | the seed is a constant, and the banner says so |

### DMA and the IOMMU

Each IOMMU the kernel drives has a driver of erXos's own, in the platform
layer, which the binding names
([design-arch-aarch64.md](design-arch-aarch64.md#iommu)). At boot it first
makes the IOMMU abort every transaction it does not translate, while
translation is off as well as once it is on, before the kernel reclaims
any memory (boot step 4, [Boot](#boot)), then reads its identification
registers, allocates its stream table, command queue and fault queue, sets
every stream to valid abort, invalidates inherited configuration and
translation caches through its own queue, and waits for completion before
enabling translation. A function without a window then reaches no memory.
Boot accepts only a proven stopped handoff with outstanding device and
IOMMU accesses drained; arbitrary live firmware state stops boot. The
kernel's DMA guarantees hold
for the devices an IOMMU confines and for no other. Each platform's **DMA
contract** says, for every bus master, whether an IOMMU translates it and
what bypasses that translation, how its requests are identified, which
path its interrupts take and whether its MSIs identify their writer, which
reset reaches it, and which error reports the platform gives
([design-platforms.md](design-platforms.md#dma)).

* **Windows.** `erx_dma_create(resource, budget)` takes the resource of
  one confined PCIe function, carved by its requester id, and creates a
  window on the stream the bridge's `iommu-map` gives it: translation
  tables in the format the IOMMU shares with the CPU, charged to `budget`,
  and the stream's entry in the IOMMU's tables, written and then published
  with the IOMMU's synchronisation. Every window maps the page of the
  platform's MSI frame at `ERX_DMA_MSI_IOVA`, so the function's MSIs pass
  translation. Functions whose requester ids map to one stream, as every
  function behind a bridge that takes over the requester ids below it
  does, form one isolation group ([Resources, DMA windows and
  consoles](#resources-dma-windows-and-consoles)), share that stream's one
  window, and so share a driver and a trust boundary. A frame that takes
  its line from the value written cannot tell which function wrote it, so
  every function that can write the frame can raise any of its lines: the
  drivers of those functions share one trust boundary for interrupts,
  which costs another driver at most spurious deliveries, since a line
  stays masked until its delivery is taken ([IRQ objects](#irq-objects)).
  Only a frame that identifies its writer gives each function lines of its
  own, and the platform's contract says which frames do.
* **Mapping.** `erx_dma_map(window, iova, size, memory, offset, prot)`
  maps pages of a memory object through a capability the caller holds with
  the rights `prot` needs, only pages the object owns exclusively
  ([Copy-on-write children and copies of spaces](#copy-on-write-children-and-copies-of-spaces)),
  in a mapping record that joins the window's records and attaches to the
  object's reverse map through the one insert function, which refuses a
  closed window or object with `ERX_ESTALE`; like `erx_dma_unmap`, it
  holds the window's existence lock
  throughout ([Execution model and
  locking](#execution-model-and-locking)). So the mapping lasts until
  `erx_dma_unmap`, the window's destruction or the object's deletion,
  whatever becomes of the capability. `erx_dma_unmap` clears the entries,
  invalidates the IOMMU's cached translations of them, and only after the
  invalidation completes detaches the mapping record from the object
  (K9), so no DMA
  lands in a page after it is freed: the binding names the invalidation's
  completion observation and the barriers that order it before
  reclamation, and requires the completion's visibility domain to cover
  the reused memory
  ([design-arch-aarch64.md](design-arch-aarch64.md#iommu)). That
  completion covers only the requests the IOMMU has already translated: a
  device that kept an old address, as a stale descriptor does, and uses it
  after the unmap reaches whatever is mapped at that address then. So the
  DMA envelope beneath the device NIF maps a buffer at an address that
  named another one only after the device's completion protocol has
  retired every request that named the old buffer, or after the device has
  been reset, and otherwise leaves the address unused, a quarantine that
  lasts until one of those has happened
  ([design-runtime.md](design-runtime.md#the-device-nif)); both buffers
  lie in the same window, so a stale request reaches only memory its own
  driver was given, and never a page the kernel has freed. The kernel
  waits for each completion with a deadline, `ERX_IOMMU_SYNC_NS` (one
  second), polling between preemption points. An IOMMU that misses it has
  **failed**: the kernel logs it, refuses every later window and mapping
  on it with `ERX_EDEAD`, and frees none of the pages whose invalidation
  it was waiting for: those pages are **pinned**. A pinned page stays in
  its object's record, which is then never freed, as a dead budget's
  tombstone is kept, and stays charged to its budget for the rest of the
  boot. **Pinning** is one adjustment, `erx_budget_adjust` with a change
  of `pinned`, which raises `pinned` at the page's budget and at every
  ancestor up to the root, dead ones included, as a charge beyond a
  guarantee passes `lent` up the chain, and never fails, since it admits
  nothing: `pinned` at a budget is thus the pinned pages anywhere in its
  tree, a close moves none of it, and what a destroy of the budget would
  give its parent back is its guarantee and borrowing less `pinned`
  ([Budgets](#budgets)). A pin also pins, at once, the cache page of
  every record it keeps for the boot: the record of the page's object,
  and the record of each budget, live or dead, whose `pinned` the
  adjustment raises from zero, since that record is kept whenever its
  budget dies. Each such page is pinned at its cache's budget by the
  same adjustment, from which the pin passes up in turn. The first
  kept record on a page marks the page's header and pins the page, and
  a later one finds the mark and adds nothing, so the count is exact
  and a pin is idempotent; a close marks nothing, since every record a
  close would keep was marked when its pin was made. So `pinned` at a
  budget counts, at every instant, every page of its tree that no
  destroy will give back, the cache pages of the records a destroy
  keeps included, and the inspector's figure for a destroy, the
  guarantee plus the borrowing less `pinned`, is what the destroy gives
  back. So
  DMA that a stuck IOMMU still lets through
  never lands in memory the kernel has reused. Its invalidations follow
  from what it cleared, as the CPU's do
  ([Virtual memory](#virtual-memory)): a cleared entry that points to a
  table of the window takes the IOMMU's invalidation of every level over
  that table's span, so the IOMMU never walks a freed table. A window lets
  no function cache translations of its own or ask for pages: the binding
  disables both and also rejects traffic falsely marked already
  translated, so a disabled endpoint feature cannot become an IOMMU
  bypass. A deletion of the object does the same ([Closing and
  deleting](#closing-and-deleting)), and DMA that reaches the removed
  entries aborts at the IOMMU as a fault of the window.
* **Faults.** The fault queue's interrupt is the kernel's own. The IOMMU
  writes the queue, not a device, but a device chooses how often it
  faults, so the record decoder is a pure function with a host fuzz
  target, and what any device can make the kernel spend on its faults is
  bounded without waiting for a user-mode party:
  * The handler drains at most `ERX_IOMMU_BATCH` (64) records per
    interrupt and `ERX_IOMMU_FAULTS` (256) per 10 ms period over all
    windows. Past that it masks the queue's interrupt until the period
    ends, and the records the IOMMU cannot queue meanwhile it drops and
    flags as an overflow. The kernel counts overflow episodes and reports
    the number of lost records as unknown. Isolation never
    rests on a record: a faulting access aborts at the IOMMU whether or
    not its record is read.
  * It checks each record's stream id against the stream table and counts
    one of a stream without a window on the IOMMU itself.
  * It counts each other record on the window of its stream and fires the
    IRQ object that `erx_dma_bind(window, irq)`, with `BIND` on the window
    and `TRIGGER` on the IRQ object, named for its faults. A window with
    more than `ERX_DMA_FAULTS` (64) records in one period is
    **quarantined**: the handler sets its stream's entry to valid abort, which
    records no fault, and queues the commands that make the IOMMU read
    the entry again, with a synchronisation it does not wait for, since
    a quarantine frees nothing: the window's pages stay mapped and
    charged until its destruction, which waits for its own
    synchronisation. A command queue without room for them leaves them
    to a bounded retry at the next period even without another interrupt.
    Once the IOMMU has completed them, the window's device
    reaches no memory and raises no more records. A quarantine lasts
    until the device service destroys the window, after resetting the
    function, and `erx_object_info` reports it.
* **Destruction.** Destroying a window, in the call that deletes or
  releases it, closes and drains it, so no `erx_dma_map` or
  `erx_dma_unmap` is still changing it and none can begin (K26), writes
  its stream's entry back to abort, publishes it and waits for the
  IOMMU, and then detaches every mapping record from its object in
  bounded parts, as `erx_dma_unmap` does. The device service resets a
  function, by the reset its platform's contract names, before it has a
  window created for the function's next driver, so no request that the
  previous driver left queued in the device runs under the next driver's
  window ([design-system.md](design-system.md#devices)). A failed or
  unverified reset leaves the function and its requester identity
  unavailable to another driver; closing the IOMMU window alone does
  not prove the device discarded queued requests. The closing window
  retains its stream reservation until the binding retires every old
  fault event: after reset and drain, a sync and queue-producer snapshot
  delimit the old records to consume or discard. Old events cannot be
  charged to, or quarantine, a new driver on the same stream.

A device without an IOMMU is **unconfined**: its DMA can reach all memory,
code and every domain's pages included, so the device clauses of K8 and
K22 do not bind it, and the domain that holds it and the device are part
of the trusted base, which is why a release configuration gives each such
device a domain of its own ([design-system.md](design-system.md#devices)).
Its driver programs the device addresses of contiguous memory objects it
holds, and never computes one itself: a device may see RAM at addresses
other than the CPU's, where a physical address would be wrong
([design-platforms.md](design-platforms.md#dma)).

* **Ranges.** `erx_dma_ranges(device, limit)`, a pure function of the
  device tree, gives a device's DMA ranges: each a range of RAM and the
  device address at which the device sees its start. It reads
  `dma-ranges` as Linux does (`of_dma_get_range` and
  `of_dma_configure_id`,
  [research](research-boards-storage.md#linuxs-reading-of-dma-ranges)):
  walking up from the device's bus, a level with an empty `dma-ranges`
  passes addresses unchanged, and the first level with a non-empty one
  defines the ranges, whose parent addresses translate to CPU addresses
  through every level above; a level without the property, once the walk
  has passed the device's own bus, or a walk that reaches the root without
  a defining level, leaves the device's addresses equal to the CPU's. It
  keeps only ranges backed by RAM, so a PCIe bridge's loopback and MSI
  windows drop out, and it cuts every range below `limit`, the highest
  device address the driver says its device can generate, which can only
  narrow the result. Its host tests use the trees of every platform
  ([design-platforms.md](design-platforms.md#dma)) and a fixture tree for
  each case of the walk.
* **Objects.** `erx_mem_create_contiguous(budget, resource, size, limit)`
  allocates inside one range of the device the resource names, so the
  object's device addresses are contiguous, and fails with `ERX_ENOMEM`
  when no range has room. It draws only from the **contiguous pool**,
  `erx.dma_pool` bytes of the lowest RAM that the kernel sets aside at
  boot, before it makes the root budget, and that no other allocation
  uses, so ordinary allocations cannot take the memory that devices with
  an address limit, such as a legacy DMA engine that reaches only the
  lowest GiB, can reach. The pool is outside the root budget's pages and
  outside the reaper's identity: its pages are never in a reserve's
  pool, on the released list or on the free lists, and they back no
  ordinary charge ([The reaper](#the-reaper)). A contiguous object is
  nevertheless charged to its budget, page for page, through
  `erx_budget_adjust` as every allocation is (K3), so a driver's DMA
  memory is bounded by its budget, and ordinary charges are bounded by
  the allocator's pages less what contiguous objects hold, which is on
  the safe side. The pool keeps its own count, pages in contiguous
  objects plus its free ranges; a creation that finds no range with
  room refunds its charge and fails; and an object's range returns to
  the pool's free ranges when the object is destroyed, which the device
  service does only after it has reset the device (**Lifetime** below),
  never to the released list. For a device that is
  not `dma-coherent` it allocates whole cache-writeback granules, whose
  size the CPU reports, so no cache line holds a byte of another object.
  `erx_mem_dma_addr(mem, offset)`, which needs `PHYS`, returns the
  device's address for an offset in it.
* **Lifetime.** An unconfined device can write its memory whatever any
  table says, so nothing a device may still write is ever freed: the
  system domain's device service creates every contiguous object from its
  own budget, keeps it for the whole boot and passes it, without
  `DESTROY`, to each driver of the device in turn
  ([design-system.md](design-system.md#devices)). The end of a driver's
  domain, which destroys that domain's budgets, therefore frees none of
  it. A confined device's memory needs no such rule: the system domain
  charges its pools to the driver domain's own budget, and the kernel
  frees a page a window mapped only after it has removed the page from
  the window and the IOMMU has completed the invalidation (K9), whatever
  ended the object, so the pools go with the domain once its window is
  unbound.
* **Release builds** refuse to create contiguous memory unless the boot
  image carries `ERX_PACK_UNCONFINED_DMA`.

**One binding for each piece of hardware that cannot be shared.** An
interrupt line has at most one IRQ object, an IOMMU stream at most
one DMA window, a register page at most one MMIO object (a second fails
with `ERX_EBUSY`), no MMIO object covers a page of a device the kernel
drives, and the memory attributes are fixed at boot (normal write-back and
the binding's two device attributes), so no object can change what another
relies on. The system domain's device service creates every IRQ object of
a device and every window, and gives the domain that the system
configuration names for the device a masked capability of its own: an
IRQ object with `BIND` and `ACK`, which the driver binds to its group so
that the interrupt reaches it as an event, and a window with `MAP`
([design-system.md](design-system.md#devices)).

**The primitives the DMA envelope uses**, beneath the device NIF or a
native shim in a sub-space
([design-runtime.md](design-runtime.md#the-device-nif)): `erx_dma_map` and
`erx_dma_unmap` on the driver's window, for a confined device;
`erx_mem_dma_addr` on contiguous memory, for an unconfined one; cache
maintenance by virtual address in user mode, where the architecture allows
it ([design-arch-aarch64.md](design-arch-aarch64.md#cache-maintenance)): a
clean before a device reads a buffer, and a clean and invalidate both
before a device writes a buffer, so no dirty line can later be evicted
over what the device wrote, and after, but never an invalidate alone, so a
driver can never discard data it did not write; skipped for a device the
device tree marks `dma-coherent`, and ended with a barrier before the
envelope writes the device's doorbell, so the device sees the maintained
data; and the device's IRQ objects, acknowledged as their kind requires
([IRQ objects](#irq-objects)).

### The reaper

Freeing never happens inside the call that drops the last reference, and
no admission ever waits for it: a charge ends when memory is released,
the reaper only turns released memory into free memory, and what a
backing may wait for is the grace period of pages it took off the
released list itself, never a reaper step (**Backing a charge** below).
It does three kinds of work:

1. the **puts** of destroyed objects, each the drop of an object's own
   reference, which wait until the grace period that began after the
   object's destroy has ended ([Execution model and
   locking](#execution-model-and-locking)), and the **frees** of records
   whose last counted reference has gone, or, for a space, whose last
   child's record has been freed since, each the return of a slot to
   its budget's cache and, when the cache page then holds no record, the
   release of that page;
2. **released pages**: data pages, pooled pages, translation tables,
   cache pages and kernel stacks, which wait until a grace period that
   began after their release has ended, so that no translation (K9) and
   no walk of `erx_uword_load` that found a page reads freed memory
   ([Umtx](#umtx));
3. retiring ASIDs whose invalidation has completed.

**The released list.** Every page leaves its reserve through one
function, `erx_page_release(reserve, pages)`, which a teardown, a range
call, a cache whose page holds no record or the drop of a dead thread's
stack calls from a part that holds no spinlock, existence locks aside.
It appends the pages a part releases to the machine-wide **released
list** as one **batch**, chained through their page records, stamped by
the tracker's retire (**Stamps** below), under the list's lock; then it
takes them out of the reserve's `backed` and `charged` and refunds their
charge through `erx_budget_adjust`, in the same bounded part. The append
comes first, so a charge admitted on the refund finds the pages on the
list already. The list is in append order and stamps never decrease
along it, so the head's period ends first. A released page belongs to
no reserve and no budget: `used` counts what is charged and not
released. Puts and record frees are not pages: each is retired the same
way, stamped at its retirement, and waits on the list of the CPU that
queued it, in the order queued, since no charge depends on when it
runs. Retiring ASIDs, which no budget pays for, wait on their CPU's own
list.

**Stamps.** The tracker keeps two 64-bit counts, the current period and
the last completed one, as Fiasco's `Rcu_glbl` keeps its batch numbers;
the current count is at most one above the completed one, and a period
is in progress exactly while it is. A release, a put or a record free is
**retired** through one function, `erx_grace_retire`, which, under the
tracker's lock, a ticket lock at level 9 of the order (K13), returns the
item's stamp, the current count plus one, and requests that period: if
none is in progress it starts it there, taking the set of active CPUs it
must hear from, as Fiasco's `start_batch` does, and otherwise marks it
pending, so that the completion of the period in progress starts it at
once, which is what Fiasco's `process_callbacks` does for a callback
(`rcupdate.cpp`). A stamped item is mature once the completed count has
reached its stamp, compared as plain integers. The stamp must name a
period that **begins after the retirement**: a period already in
progress may have heard from a CPU before the release, and that CPU may
have taken a translation of the page, or a pointer to the record, since
then, so completing that period proves nothing about it; the next period
hears from every active CPU after the retirement, which is the
guarantee. So an item matures after at most the rest of the period in
progress and one whole period, fewer than two grace periods, and every
bound on a release in this document is that. The current count advances
only when a period completes, which takes every active CPU through a
quiescent point, so it advances at most once per such pass; at one
advance a nanosecond, faster than any machine takes every CPU through a
quiescent point, the count reaches its last value after 584 years. So
the count does not wrap within a boot and no stamp is ever compared
across a wrap; at the last value the kernel panics rather than wrap, an
end no user-mode thread can bring about (K12). The host model builds the
tracker with a narrow count, drives it to the last value, and checks
that every maturity decision before it was right and that the end is the
panic, with a seeded modular comparison, which the model catches as a
batch freed before its period. It also retires an item while no period
is in progress, and one after a CPU has reported its quiescent state for
the period in progress, and checks in both that the item is not mature
until a period that began after the retirement has heard from every
active CPU, with a seeded retire that stamps the current count, under
which the second item matures while that CPU still holds its pointer.

**The identity.** Between parts, every page of the root budget's
guarantee is in exactly one of four places: held by a reserve, in use or
in its pool; in the **hand** of a backing, a call that took it and is
waiting for its grace period to end before it joins the reserve's pool;
on the released list; or on the page allocator's free lists. With `N`
the root's guarantee, `H` the pages held, `I` the pages in hands and `C`
the pages admitted to every reserve, `free + released = N - H - I`, and
`H <= C <= N`, since a page enters a reserve only by the backing of a
charge, leaves it only by a release that refunds, and an admission is
counted until it is backed or cancelled (K32). While a backing runs, the
pages of its charge are of two kinds: **selected**, taken into its hand
and not yet in the pool, and **unselected**, admitted and not yet
taken; `C - H` is both kinds over every backing under way, and `I` the
selected alone. So the unselected pages, `C - H - I`, never exceed
`free + released`: a backing that still needs a page always finds one
free or on the list, provided every admission not yet backed is still
counted in `C`, which the cancellation rule below keeps true.

**Backing a charge.** `erx_reserve_charge(reserve, n)` is the one source
of pages. It admits `n` pages through `erx_budget_adjust`, and takes
nothing when the charge is refused; then it backs them, in parts of at
most 64 pages with a preemption point after each. The reserve's owner
is an object on its budget's list, one the budget's destroy can reach,
and the caller holds the owner's existence lock from before the
admission until after the last part: a range call its space's for its
length, a map its space's, a copy of a space `to`'s for the private
memory and tables it makes in `to`, and a creation its construction
record's, which owns what is being made until it is published
(**Construction** below). The owner's destroy drains that lock, helping
the backing through its remaining parts ([Execution model and
locking](#execution-model-and-locking)), so no teardown ever begins
while a backing of the owner's reserve is under way, and a teardown
finds `charged` equal to `backed`, which debug builds assert. A part
takes the list's lock and then the allocator's, both ticket locks
(K13), and takes what it still needs: free pages first, then pages off
the head of the released list, oldest first, and no more than it needs;
it releases both locks, and if any page it took bears a stamp the
completed count has not reached, it waits at preemption points, polling
the completed count, sleeping on no record and holding no spinlock
(K13, K33), until the count reaches the newest such stamp, fewer than
two grace periods away (**Stamps**). Then it takes the owner's lock and
puts the pages in the reserve's pool, raising `backed`. Between parts
it reads every existence lock its thread holds, the owner's and those
of the operation the backing is part of, a copy's two among them: a
backing that finds any of them **closed** admits nothing more, puts the pages it has selected into the
pool once they are mature, cancels the unselected rest through
`erx_reserve_cancel`, which lowers `charged` by that many and refunds
them through `erx_budget_adjust`, a decrease that never fails, at the
owner's budget, live or dead, and returns `ERX_ESTALE`. It releases no
page itself: the owner's teardown, which the drain holds back until the
lock is released, releases everything the reserve holds, pool included,
exactly once. So an admission ends in exactly one of two ways, backed in
full or cancelled by the backing that made it; a page leaves a reserve
only by the owner's own paths, its teardown and its range calls, never
by a backing; and `C` counts every admission until then. The one
backing under no existence lock is a budget's cache page, which has no
owner but the budget:
`erx_kalloc` admits one page at the budget, which refuses a dead budget,
takes and waits as above, and under the budget's lock carves the record
it needs from the page; a budget that died meanwhile has no record to
carve, so the page holds none and is released there, by the cache's own
rule that a page holding no record is released, whose refund lowers
`charged` with it. A
backing never finds the free lists and the released list both empty
while it needs a page, by the identity's inequality: the unselected
pages are at most `free + released`, and the page this backing needs is
one of them. So a part always takes what it needs and waits fewer than
two grace periods, whatever other CPUs do, and a backing never loses a
page it took, since nothing takes a page out of a hand: an admitted
charge of `n` pages is backed within one part per 64 pages, each
bounded by two grace periods and by `ncpus - 1` critical sections of
each of its two locks, and no backing waits on another party (K6, K13);
a release's part is bounded the same way by the list's lock and the
tracker's, which it takes inside it, and a put's or a record free's by
the tracker's alone.
Those bounds are the machine's time; the backing's own parts run on its
thread's group's grant, so what its caller sees elapse is that plus
whatever its own group leaves it unscheduled, which is its own party's
doing and nobody else's. A fault takes nothing from the allocator: it
takes from its reserve's pool, through `erx_reserve_take`, under the
owner's lock, which zeroes the page and hands it out, and the pool holds
a page for every promise not in use, so a fault never waits and never
fails ([Virtual memory](#virtual-memory)).

**Construction.** An object comes into being under a **construction
record**, an object of type `ERX_K_CONSTRUCTION` that owns what is
being made until the object itself does:

```c
typedef struct erx_construction {
	erx_object_t	 obj;		/* on its budget's att_charged from its
					 * insert; its existence lock is held by
					 * the creator throughout */
	erx_reserve_t	 reserve;	/* the pages admitted and backed so far */
	erx_object_t	*object;	/* the record being made, once it exists;
					 * reachable through nothing else */
} erx_construction_t;
```

A construction record is never named by a capability and never
released; it is on exactly one list, its budget's, from its insert
until the object replaces it there or its creator tears it down. A
creation runs in five steps, in the creator's call, which runs to its
end whatever happens to the creator meanwhile. The handler owns the
first four and the generated dispatch the fifth, and what passes
between them is one counted reference. `erx_kalloc` hands every record
to its caller **counted**: the record carries its own reference, which
its put drops after its grace period, and the caller's, which the
caller keeps across the preemption points of the creation and passes
on or drops where the steps below say. So from its allocation to the
slot that names it the object is held counted by one thread at every
moment, first the creator and then the dispatch, and no destroy that
races the creation frees the record under a pointer the creation still
uses.

1. *The construction record (the handler).* The creator takes it from
   its budget's cache through `erx_kalloc`, counted, takes its
   existence lock through `erx_object_lock_fresh_existence`, the take
   for a record only its caller can reach, which finds the lock free,
   and inserts it into the budget's `att_charged` through the list's
   insert function, which refuses a closed budget with `ERX_ESTALE`.
   From this insert on the construction is one the budget's destroy
   can reach, and everything the creation charges is charged to a
   reserve on the budget's list.
2. *Backing (the handler).* The creator admits and backs the object's
   pages through `erx_reserve_charge` into the construction's reserve,
   in parts as above, under the construction's lock. The object's own
   record comes from the budget's cache through `erx_kalloc` before
   publication, counted for the creator as the construction record is,
   or, on the stopgap, where a thread's record is its block, is made in
   the pages the backing produced with the same two references
   ([design-stopgap.md](design-stopgap.md#budgets-and-the-ownership-of-pages)).
   A budget destroyed meanwhile closes the construction and drains its
   lock, helping the creator through the steps that remain: the backing
   finds the construction closed at its next part, admits nothing more,
   cancels what it has not selected, and returns `ERX_ESTALE`, and the
   creator goes to step 4.
3. *Publication (the handler).* The creator takes the object's own
   existence lock, through `erx_object_lock_fresh_existence` again,
   and holds it across the inserts that make the object reachable, in
   one order. Under the budget's lock it replaces the construction
   record by the object on `att_charged` and moves the reserve, its
   counts and its pool, into the object; the budget's destroy takes
   each item of the list under the same lock, so the walk finds the
   construction or the object, never both and never neither, and the
   replacement refuses a closed budget with `ERX_ESTALE`, changing
   nothing. Then it inserts the object into its container, a thread
   into its space's `threads`, a child into its parent object's
   `att_children`, a space into its parent's children, under the
   container's lock, which refuses a closed container the same way.
   Then it releases the object's existence lock alone, through
   `erx_object_unlock_fresh_existence`, and keeps its counted
   reference. A destroy that reaches the object through the budget's
   list or its container between the inserts drains the object's
   existence lock first, so its teardown begins only once the inserts
   are done and detaches exactly what they attached; one that reaches
   it after the release runs at once, and finds the record allocated
   for as long as the reference lasts ([Execution model and
   locking](#execution-model-and-locking)).
4. *The handler's end.* A charge refused, an insert refused or any
   other failure before the object is published first destroys what
   the creator made, through the same close, drain and teardown as a
   deletion's ([Closing and deleting](#closing-and-deleting)), after
   releasing the object's existence lock if it holds it and every
   existence lock it holds beside the construction's, a copy's two
   among them, so that the teardown runs under the construction's lock
   alone and keeps no other object's destroy waiting: the teardown
   finds attached exactly what the creator had attached, releases every
   page the reserve holds, the construction's or the object's, through
   `erx_page_release`, refunding at the budget, live or dead, in parts
   bounded by the pages that were backed, and queues the record's
   free; the creator drops its reference on the object once the
   teardown has run; a creation has no undo path of its own. Then,
   published or not, the creator releases the construction's lock and,
   in the same part, closes the construction record and drops its
   reference on it: a close that finds it closed already, by its
   budget's destroy, does nothing more, and otherwise the ordinary
   deletion follows, with nothing to tear down, and the record goes to
   the reaper after its grace period as every record does. A handler
   that published returns its object, still counted, as the call's
   result, and holds nothing else of the creation when it returns.
5. *Installation (the dispatch).* The generated dispatch, which emits
   this step for every call whose result the ABI file declares as a
   created object, owns the reference from the handler's return to the
   call's completion. It takes the object's capability lock with
   `erx_object_lock`, the take for an object held counted, which may
   help its holder and so pass a preemption point that the reference
   carries the pointer across; under it, and under the table's lock, it
   fills a free slot of the creator's table with the capability,
   raising `ncaps` from zero to one, and that capability is the call's
   result. It fills nothing when the lock's one state word says the
   object is closed, by a destroy that reached it through the budget's
   list or its container, or when the table has no free slot and cannot
   grow within the space's capability limit and budget ([Passing
   capabilities](#passing-capabilities)). An object no slot names when
   the dispatch releases the lock, the dispatch destroys, as the
   deleting call destroys one: the close that finds it closed already
   does nothing more, and otherwise the close wins, the drain finds the
   lock free, and the teardown detaches exactly what step 3 attached
   and queues the put. The completion then drops the reference, a last
   drop queueing the free as every last drop does, and the call fails
   with `ERX_ESTALE` for an object closed meanwhile and with
   `ERX_ELIMIT` or `ERX_ENOMEM` for a table with no slot.

So a construction ends in exactly one of two ways, published and
installed, or torn down by the one teardown, the creator's or the
dispatch's; from its first charge until the object is published or torn
down the charge has an owner on the budget's list, the construction
record, whose existence lock the creator holds, and from then on the
published object carries it, through the counted reference the dispatch
owns until installation or destruction, the creator holding no lock of
the construction through the dispatch: the budget's
destroy cancels the backing and helps the creator through its teardown
on the destroyer's time, as it drains any charged object, and finds the
refund made when the drain returns, so a creator without CPU time
cannot keep a charge at a dead budget; the object is reachable to a
destroy only while the creator holds its existence lock or once every
insert is done, so nothing is ever attached to a torn-down object; no
object is ever live with no slot and no thread about to install one,
since the dispatch destroys what it does not install; and `C` counts
the admission until it is backed or cancelled, so the identity holds
through it. A copy of a space, which holds two existence locks,
`from`'s and `to`'s, makes each fresh copy-on-write child this way,
holding the child's construction lock and then the child's own beside
them, and fills `to`'s table itself, under the child's existence lock
in step 3, since the copy and not the dispatch installs what it makes
(K17), dropping its reference on the child when the slot is filled; a
backing reads every existence lock its thread holds between its parts,
so a destroy of `from` or `to` cancels the child's backing at its next
part, and the copy releases the two spaces' locks before it tears the
child down (**Copying**, [Copy-on-write children and copies of
spaces](#copy-on-write-children-and-copies-of-spaces)). The stopgap's
thread block is step 2's case, its record made in the backed pages
([design-stopgap.md](design-stopgap.md#budgets-and-the-ownership-of-pages)).

**Steps.** The reaper works in bounded steps: one step runs up to 64
puts and record frees of its CPU's list whose grace period has ended, in
the order they were queued, or moves up to 64 mature pages from the head
of the released list to the page allocator's free lists through
`erx_page_free`, under the list's lock and then the allocator's, or
retires up to 64 ASIDs, and returns;
nothing is held across a preemption point, and a batch of more than 64
pages goes in several steps, by whichever CPUs run them. A record free
may release a cache page, which is an append, never a recursion, and a
put may release further references, which queue further puts, so a
chain of any length is a loop. A step that finds the head of the
released list immature does nothing with it; it is not a wait.

**Who runs steps.** Each CPU runs reaper steps in three places. In its
idle thread, before it waits for an interrupt, it runs steps of every
kind with a preemption point after each until none has work: a batch is
eligible once mature, an idle CPU frees eligible pages 64 a step until
the head is immature, and revisits that head on its next idle pass; so
after an idle pass that ended at an immature head, the released list
holds only batches whose period has not yet ended and the free lists
hold the rest, until the next release. At its **reap deadline**: a CPU
whose list holds a mature item keeps a deadline on its timer wheel no
further than `ERX_REAP_NS` (one millisecond) ahead
([design-scheduler.md](design-scheduler.md#timers-ticks-and-deterministic-mode)),
runs one step of that list at the first preemption point or return to
user mode after the deadline's interrupt, and re-arms the deadline if a
mature item remains. So a CPU that runs user code without pause serves
its list at 64 items per `ERX_REAP_NS`, in the order queued, and an
item queued on a CPU behind `b` mature items runs within its grace
period, `1 + floor(b / 64)` deadlines and one part, whatever the other
CPUs do, and sooner on a CPU that idles. The items ahead of it were
queued by calls that ran on that CPU, each the deferred end of a destroy
that a budget paid for, so what one party can put ahead of another's
items is bounded by the records its budgets hold, a cost stated in
[Security](#security); the stopgap's deadline is its tick, one step per
tick
([design-stopgap.md](design-stopgap.md#budgets-and-the-ownership-of-pages)).
And after `erx_space_stop` and capability closes, a few steps at the
end of the call, within its bound. Backing a charge is not a step: it
takes released pages for its own reserve, above, and takes no more than
it needs. Freeing is therefore paid for by whoever backs a charge when
no page is free, and otherwise takes idle time and one bounded step per
deadline; no reservation and no thread of its own serve it. Destroys
are not the reaper's: an object's teardown runs in
the call that deleted or released it, the call that removes a released
memory object's last mapping included, and a thread's own part runs on
the thread ([Closing and deleting](#closing-and-deleting)); nor is
waking a stopped space's waiting threads, which the stop call does
([Threads and faults](#threads-and-faults)); only the three kinds of
work above come here.

**Single pages.** The allocator hands out single pages and nothing
larger. erXos's kernel takes single pages for everything, and its kernel
stacks are mapped into their slots of the stack region page by page; the
stopgap's thread blocks are two single pages mapped into an aligned slot
of its thread region
([design-stopgap.md](design-stopgap.md#budgets-and-the-ownership-of-pages));
and the contiguous pool is separate and outside the identity ([DMA and
the IOMMU](#dma-and-the-iommu)). So the identity counts exactly what a
backing can take, and no admitted charge can find that its pages exist
but not in the shape it needs.

**What backing a charge can cost, and who can impose it.** A backing
that finds no free page pays, per part of at most 64 pages, a wait of
fewer than two grace periods, and pays it only while the machine has no
free page, whoever released the pages it takes; an admitted charge of
`n` pages costs at most one such part per 64 pages, bounded by its own
size, never by the attempts of others, since its two locks serve takers
in order and nothing takes a page out of its hand. The free pool is
machine-wide, so that cost crosses walls. The released list holds at
most the machine's pages: a domain that releases and charges without
pause moves at most the machine's free pages onto the list before its
own backings must take from the list, and from then on it cycles its
own pages, each cycle a range call, a backing that waits its periods,
and a fault, on its own CPU time; while it churns the free pool stays
empty, every other domain's backings take from the list and pay that
wait per part, and idle CPUs free released pages ahead of anyone. That
is the one cost the budgets do not wall off, stated with its bound in
[Security](#security).

**The interface every implementation's page funnel meets.** Six
entries, and no other path to a page: `erx_reserve_charge(reserve, n)`
admits and then backs, under the owner's existence lock, and takes
nothing when the charge is refused; `erx_reserve_cancel(reserve, k)`
gives back promises a backing did not take, and is called only by the
backing that made them, when it finds its owner closed;
`erx_reserve_take(reserve)` moves a page from a reserve's pool into use,
under the owner's lock, zeroing it, and is the only way a page comes
into use; `erx_page_release(reserve, pages)` retires, appends and then
refunds, in one part, and is the only way a held page's hold and promise
end; `erx_released_take(n)`, the only way pages leave the released list,
serves the free step, which puts mature pages on the free lists through
`erx_page_free`, the sink, and the backing, which keeps what it takes;
and the boot allocator exists only before the root budget does. Beneath
them the tracker's one retire, `erx_grace_retire`, stamps every release,
put and record free at its retirement, and the list's, the allocator's
and the tracker's locks are the
core's ticket locks. The allocator's own take and put are referenced
only from the backing and the free step, in `kernel/core/page.c`; the
stopgap's `erx_page_free` is that put. A page is in exactly one of the
four places of the identity at every instant between parts ([Chokepoint
checks](#chokepoint-checks)).

### Console, log and panic

**The early console.** The kernel writes one UART, whose kind and
address the platform's kernel build fixes: the UART the board documents
as its console, on QEMU `virt` the PL011 at the address the `virt`
board fixes, on the Raspberry Pi 4 the mini UART its firmware makes the
console, and on the Raspberry Pi 5 its debug PL011
([design-platforms.md](design-platforms.md#uarts)). It writes it from
the first step of its boot, at that physical address while translation
is off and afterwards through the one page step 3 maps for those
writes. Once the early device-tree pass has read `/chosen`, the kernel
checks that `stdout-path` names a UART of that kind at that address,
and otherwise stops the boot with a message naming the path on that
UART (step 2 of [Boot](#boot)). So every stop of the boot prints its
reason, the stop on a malformed device tree included. Before the check
the kernel writes an address the build fixed, not one the tree
confirmed, so a kernel booted on a board it was not built for may write
a foreign device's registers before it stops; the board build is the
configuration, and this cost is accepted ([Risks and open
questions](#risks-and-open-questions)). The kernel keeps no register
page of the UART: the page enters the root resource like any other
device's, its own mapping serves only its writes, during boot and at a
panic or an end of the machine, and the console's driver in the system
domain owns the UART otherwise. It writes only by polling: each byte
waits for room in the UART's transmit holding register for a bounded
number of polls and is dropped after that, so a UART that a driver reconfigured or that hangs cannot hold the
kernel up. It reads only the UART's status, never a received byte, and
takes none of its interrupts. It writes it at two times: during boot,
until the console's driver takes the UART, which is the first
`erx_resource_carve` of the UART's device entry from the root resource,
and at a panic or the machine's end, after it has stopped the other
CPUs; under a partial boot, which never carves it, the kernel prints
every log record for the whole run
([design-system.md](design-system.md#boot)). In between the UART
belongs to the console's driver in the system domain: the system
manifest names the console's UART by its device-tree path, and the
device service refuses a manifest whose console path differs from
`/chosen/stdout-path`, so the early console is that one UART shared in
time ([Resources, DMA windows and
consoles](#resources-dma-windows-and-consoles),
[design-system.md](design-system.md#devices)). The host-link UART is
another device of the root resource, which the system manifest names by
its device-tree path; the kernel knows nothing of it. So no byte a domain
sends reaches a terminal through the kernel, and the only text the kernel
writes on a terminal is its own, escaped.

**The kernel log** is a ring of 64 KiB of records, each an `erx_log_record`
of the ABI file: a sequence number, a timestamp, a level and its text, with
a flag for text cut at `log_text_max`. Its core is `kernel/core/log.c`,
which reads no clock and writes no device, and its host holds one lock
around each call. Every byte of a record's text enters
through `erx_log_escape`, the kernel's own format strings included, so text
that came from outside the
trusted base (an `erx_debug_log` call, an object name, a device-tree string)
needs no separate path. It writes every byte other than
printable ASCII as `\xNN`, tabs and newlines included, using the byte classes
generated from `abi/terminal.txt`, so untrusted text can neither move the
cursor nor start a line that looks like another party's. A backslash is
printable and passes as itself, so a line that reads `\x1B` may have held
either; the rendering is for reading and is not a reversible encoding. A
token is never cut: text that does not fit a record ends at the last whole
token and is flagged. Each record renders as one line:
`#SEQ SECONDS.MICROSECONDS LEVEL TEXT`.

`erx_debug_log(len)` logs `len` bytes of the caller's
UTCB, at most its 63 message words, each word loaded once, and prefixes the
line with the caller's space and, when lines were lost before this one, how
many: `space 7 dropped 12: text`. What comes first on the line is the
kernel's, so a space cannot show another's number or a false count. `log_text_max`
holds the longest such line, so one is never truncated. The call
is limited to 16 KiB per second per space (an estimate of a
generous debugging rate), in windows of one second that open at the first
line after the last one ended; the record's whole size in the ring counts
against it, header, escaping and padding included, so a line of control
bytes costs what it occupies and a flood of empty lines is not free. Beyond
the limit lines are dropped and counted, and the call still returns
`ERX_OK`: logging is not something a program waits on or handles. A length
beyond the UTCB is `ERX_EINVAL`, and a log whose sequence numbers have run
out refuses further lines with `ERX_ELIMIT` and never reuses a number.

During boot every record is also written to the early console;
afterwards the system domain's log service reads records with
`erx_log_read(resource (TRACE), cursor, window)` into a memory window and
renders them on the console through the console's driver, so log lines
never break into the shell's output
([design-live.md](design-live.md#the-console)). The cursor is a sequence
number. A reader that falls more
than the ring behind is told how many records it lost, never shown a
partial record, and a read returns the cursor to pass next, so each loss is
told once. A window shorter than the longest record, or a cursor past the
newest record, is `ERX_EINVAL`, so a read that returns nothing means nothing
new. The bytes of a window are memory another party may reach, so its reader
copies each record's text out and checks the copy before using it, and
rendering passes everything but the newline through the escaper. A window that a party other than the log service can write could forge whole printable lines, so attribution holds only while the window stays that service's own.


**Panic.** A failed kernel assertion and an exception that violates a
kernel invariant reach `erx_panic`:

1. **One panic.** The first CPU to set the machine's panic word proceeds. A
   CPU that finds the word set by another CPU stops itself; a nested panic
   on the panicking CPU prints one line and halts, or resets while a
   machine lease is held.
2. **A fresh stack.** It switches to the CPU's panic stack, found through
   the CPU's hardware identifier and a table written at boot, so it trusts
   no pointer of the failing state.
3. **Stop the others.** It sends `ERX_IPI_STOP`; each other CPU saves its
   registers in its per-CPU record and parks with interrupts masked. It
   waits at most 100 ms for them.
4. **Report**, on the early console: the message; the CPU, its
   exception's class, cause, faulting address and return address, as the
   binding names them, and registers; a
   backtrace by frame pointers, at most 64 frames, each frame pointer
   checked to lie inside the stack it claims; the running thread, its space
   and group; and each stopped CPU's state. Every piece of text the kernel
   did not write itself passes through `erx_log_escape`.
5. **End**, as `erx.panic` says ([Configuration](#configuration)),
   through the firmware; while a machine lease is held, a reset whatever
   `erx.panic` says.

**Ending the machine.** `erx_machine_end(res, how)`, with `POWER`, which
only the root resource carries, is the orderly end. It stops the other
CPUs as a panic does, waits at most 200 ms for the UART to finish what its
driver queued, and writes a final line on the early console naming the end
it takes, after K19 below has mapped it (`erx: end off`, `reset`, `panic`
or `trial`), after which nothing writes the UART. Then it ends the machine
as `how` says:

* `ERX_END_OFF` asks the firmware to turn the machine off, which on a
  board that cannot turn itself off halts in the firmware
  ([design-platforms.md](design-platforms.md#ending-the-machine));
* `ERX_END_RESET` asks the firmware to reset the machine;
* `ERX_END_PANIC` ends as a panic does, by `erx.panic`, with a crash
  record of cause `ERX_CRASH_HALT` and an early-console line saying the system
  domain asked; the system domain's `liberx` uses it when ERTS exits
  other than by an ordered shutdown ([The root task](#the-root-task));
* `ERX_END_TRIAL` asks the firmware to boot the spare slot once, as a
  system update's trial
  ([design-storage.md](design-storage.md#system-updates)), and resets. It
  fails with `ERX_ENOTSUP`, before stopping anything, when the boot value
  is `unknown`, which it is on every platform without a trial request, so
  the system domain's own check of the boot value is the same test.
  Otherwise it arms the watchdog with its timeout, and from then on it
  never returns: it makes the platform's trial request
  ([design-platforms.md](design-platforms.md#trial-requests)) and then
  asks the firmware to reset. A request that fails or times out, or a
  reset that returns, ends in the watchdog's reset.

**K19 holds every end to a reset during a lease** ([Invariants](#invariants)):
while a machine lease is held, `ERX_END_OFF`, `ERX_END_PANIC` and
`ERX_END_TRIAL` reset, as every panic does, so a trial ends only in a
reset, whatever its code asks for, and can never request another trial of
itself. The system domain's `liberx` calls `erx_machine_end` at the end
of an ordered shutdown ([design-system.md](design-system.md#the-root-task));
every other end of the root task is a crash record and the panic path
([The root task](#the-root-task)). Under QEMU with
`-no-reboot` every end exits the emulator, which is how test runs finish;
the harness acts on `erx: end trial` only when it is the last line and
the emulator exited by itself, and boots the machine again where firmware
would.

**The machine lease** is one machine-wide deadline that only the kernel
sets: on a trial boot it takes the lease at boot step 2, for
`erx.trial_deadline`, and holds it until the machine ends, so nothing
running on the trial can end it; after a commit the system resets
([design-storage.md](design-storage.md#system-updates)). No kernel call
sets or ends a lease. While it is held:

* the kernel ends the machine as `ERX_END_RESET` when the deadline
  passes, after an early-console line saying so;
* every panic and every orderly end resets (K19);
* where the kernel drives the board's watchdog, it starts the watchdog
  when it takes the lease, with a timeout of 4 s (an estimate, within the
  Raspberry Pi watchdog's range of about 16 s,
  [research](research-boards-storage.md#checks-against-local-copies)),
  and reloads it from its timer as [The watchdog](#the-watchdog)
  describes, so a kernel that stops taking interrupts is reset by the
  hardware;
* the machine page shows the deadline, so the update service can refuse to
  start a commit too close to it
  ([design-storage.md](design-storage.md#system-updates)).

The kernel never stops a watchdog: one that the firmware started, as each
slot's `config.txt` asks for, it reloads from the same timer for the
machine's life, so a hung kernel resets the board on every boot, trial or
not ([The watchdog](#the-watchdog)).

### Trace ring

Each CPU has a ring of 4,096 records of 64 bytes:

```c
typedef struct erx_trace_record {	/* a sequence-counted record */
	_Atomic uint64_t seq;		/* 2 * index + 1 while written, then 2 * index + 2 */
	_Atomic uint64_t time_ns;	/* monotonic */
	_Atomic uint32_t event;		/* ERX_TR_*, from the ABI file */
	_Atomic uint16_t cpu;
	_Atomic uint16_t flags;
	_Atomic uint64_t thread;	/* object id of the running thread, or 0 */
	_Atomic uint64_t space;		/* object id of its space, or 0 */
	_Atomic uint64_t arg[3];
} erx_trace_record_t;
```

The kernel records dispatches and preemptions, yield requests and grace
overruns, throttles and refills, parks and wakes, IPC sends, receives and
replies, IRQ deliveries, upcalls, releases, faults, interrupts, budget
refusals, asynchronous errors and panics. A CPU writes only its own ring,
with interrupts masked, so writing never blocks, never allocates and never
takes a lock. Each record is a sequence-counted record ([Sequence-counted
records](#sequence-counted-records)), and the CPU is its one writer: it
stores twice the record's index plus one before it writes the fields and
twice the index plus two after them, so a reader on another CPU keeps its
copy of a record only if the count it read twice is even, unchanged and
names the index it expected, and counts any other record as overwritten.
`erx_trace_read(res, cpu, cursor, window)`, with `TRACE` on the root
resource, copies records from the cursor that way into the caller's
memory window ([Arguments and results](#arguments-and-results)) and
returns the next cursor and how many were overwritten before they were
read; the tracer merges the rings
by timestamp ([design-live.md](design-live.md#tracing)).
Before doubling the cursor would overflow the 64-bit sequence encoding,
the CPU stops publishing trace records and reports trace exhaustion.
It never wraps or resets its cursor or a live ring's sequence counts.
Reduced-width tests suspend a trace reader across ring reuse and this
terminal state, with no old record accepted as a newer publication.

### Deterministic mode

`erx.det=1` on the kernel command line, under single-threaded TCG with
instruction counting (`-accel tcg,thread=single -icount shift=0,sleep=off`)
and `dtb-randomness=off`, makes a boot's transcript byte-identical across
runs ([measured](research-baselines.md#deterministic-tcg) for the boot
probe). The kernel then starts no secondary CPU, seeds the generator with a
fixed value, uses fixed placement bases and stack-protector value, reads
time only from the instruction-counted virtual counter, sets the wall clock
to a fixed instant instead of reading the real-time clock, and says so in the
banner. A release build refuses deterministic mode and stops, since its
fixed seed would make every key and placement predictable.

What is byte-identical is bounded by what is pinned. The harness pins the
machine type, the QEMU version and the image, which
`make check-reproducible` makes byte-identical, and a boot in
deterministic mode takes no input it does not carry: its transcript is
identical from run to run for the boot and for smoke tests whose inputs
are in the image.
A run that takes input after it starts, from the host link or a disk,
reproduces only under QEMU's record and replay, which records each input
with the instruction count at which it arrived (QEMU's `replay`
documentation covers serial ports, block devices through `blkreplay` and
network packets). Broader tests compare structured event traces and check
invariants, not bytes. HVF and multi-CPU runs are never compared byte for
byte, and a deterministic run, on one CPU, is no test of concurrency,
which the host models and the multi-CPU suites cover.

### The current implementation: the modified Fiasco

Until erXos's kernel is written, a modified Fiasco implements the part of
the interface this document defines that the plan's vertical slice of the
system uses: the system domain's runtime and the live machine, domains
over connections, the command shell with its programs over pipes, and
immutable
code with one data store ([plan.md](plan.md)). erXos's kernel then boots
the same slice and replaces the stopgap, and every mechanism beyond the
slice lands on erXos's kernel alone, so none is built twice. Code above
the interface learns of a missing feature only from `ERX_ENOTSUP`:
runtimes, services, Erlang code and tools see `abi/erx_abi.txt`'s calls,
status codes and layouts on both kernels, and a call the stopgap leaves
out fails there with `ERX_ENOTSUP`, as an unknown call does. What else a
person or a tool can tell apart, on the console above all, is listed
under **Differences that remain** below. How the fork carries the
interface, the route from user mode and the transport, capabilities in
Fiasco's object space, deletion and the ownership of pages, the boot
handoff, the startup and pool plans and their charge evidence, the seam
between the C17 cores and Fiasco's C++, the crash record on the console,
and what the tests and benchmarks observe, is the stopgap binding's own
document, [design-stopgap.md](design-stopgap.md); the Fiasco mechanisms
behind stops, park and wake and charging are
[design-stopgap-scheduling.md](design-stopgap-scheduling.md)'s.

**What the stopgap carries, and how.** One table keys every feature of
the interface. For each it gives whether the stopgap carries it in full,
with a weaker guarantee that is documented and tested, or leaves it to
erXos's kernel, where its conformance tests run alone; how the modified
Fiasco carries it, with a mechanism of Fiasco's used as it is (existing),
changed (modified) or added beside Fiasco's own (added); what differs from
erXos's kernel; and which milestones of [plan.md](plan.md) rely on it.
The interface's properties are implemented inside the Fiasco kernel, not
emulated above it, so that a test that passes on one kernel tests the
same property on the other:

| Feature | On the stopgap | How the modified Fiasco carries it | What differs | Relied on by |
| --- | --- | --- | --- | --- |
| capabilities: generations and per-type rights, the one lookup, copies, closes, and passing at a rendezvous and by `erx_cap_pass` | in full | modified: Fiasco's object space reduced to a facade over the C17 capability table, whose slots carry the generation and the erXos rights word and which `kernel/core/cap.c` alone reads and writes; every lookup is `erx_cap_lookup`; a copy appends a slot to the object's list and a close clears one through `erx_cap_slot_clear`; passing at a rendezvous as `erx_pass_plan`, `erx_pass_take` under the sender's table lock and `erx_pass_install` at the one install point of Fiasco's IPC transfer, into the slots the receiver reserved, at most four items a message, once M5's design has fixed who owns a transfer with items so that the step holding the receiver stays one bounded step ([Transfer ownership](design-stopgap-scheduling.md#stop-and-exit)); `erx_cap_pass` as the same plan and apply from one task's table into another's under both tasks' existence locks, as `Task::sys_map` takes them; Fiasco's object mapping database is not built ([design-stopgap.md](design-stopgap.md#capabilities-in-fiascos-object-space)) | | M1 (copies, closes and `erx_cap_pass` in its creator's case), M5 (rendezvous transfer and the other cases of `erx_cap_pass`) |
| the capability lock and the existence lock | in full | existing: Fiasco's own, the object's lock over its slot list and its `existence_lock`; the dispatch takes the existence lock of the one argument the ABI file marks `exists` through `erx_object_lock_existence`, a handler that needs two takes them in address order, as `Task::sys_map` takes both tasks' (`task.cpp`), and the capability core takes the object's lock for every change of a slot ([design-stopgap.md](design-stopgap.md#capabilities-in-fiascos-object-space)) | | M1; K26's container test runs on the stopgap from M5 |
| deletion (K26) | in full | modified: the C17 deletion core closes the object first, by Fiasco's existence-lock invalidation changed to return the lock word's old value, so one destroy wins; waits for the lock's holder; empties its slots in bounded parts through `erx_cap_slot_clear`; runs the type's attachment teardown, which removes both ends of every attachment of the record; and hands the record to the reaper through the header's one link, which after the grace period drops the creation's reference, the fork's `Kobject::put` being that one drop and never a free, with the header's `refs` as the only count, held by the creation, by threads across preemption points, by the requester of a waited cross-CPU request across its answer wait, the stopgap's one departure from K33, and by queued requests nobody waits for; Fiasco's per-type `destroy` and `put` overrides, `Ref_cnt_obj` and `initiate_deletion` are deleted ([design-stopgap.md](design-stopgap.md#deletion)) | | M1, M5 |
| budgets as space banks: destroying a budget deletes every object charged to it and every budget carved from it; guarantees, caps, the borrowing chain, `erx_budget_resize` and `erx_budget_watch` | in full | replaced: Fiasco's `Ram_quota`, which accounts bytes at each allocation, and its allocation adapters are not built; an `Erx_budget` is the C17 core's `erx_budget_t` behind the glue's opaque header, with its kind, guarantee, cap, counters, watch and `att_charged` list, whose destroy deletes every object on the list, child budgets included, through the C17 deletion core, and the charges that remain pass to its nearest live ancestor; every change of its counters is the C17 `erx_budget_adjust` shared with erXos's kernel, so the chain, the walls, the caps, the close of a destroyed budget and the watch's crossing are the same code on both; the only thing the fork charges is a whole page, through `erx_reserve_charge`, which backs what it admits, and `erx_page_release`, at which a charge ends, before the page is freed; tables come through `Erx_table_alloc` over the space's reserve and records from the budget's caches, so no allocation of the fork is accounted outside the funnel ([design-stopgap.md](design-stopgap.md#budgets-and-the-ownership-of-pages)); deleting a Fiasco factory leaves the objects it made, and a Fiasco quota is fixed at its creation | | M1, M5 |
| kernel memory | in full | modified: memory objects' pages come from Fiasco's kernel allocator through the budget-charging funnel, which charges a reserve and backs it with whole single pages in the same call; a page comes into use only from its reserve's pool, leaves its reserve only through `erx_page_release`, onto the machine-wide released list, retired to the batch after Fiasco's current one and chained through page records the fork adds for the heap, and reaches Fiasco's free lists only through the reaper's free step once that batch has completed, unless the backing of a charge takes it off the list and waits for the batch itself, as [The reaper](#the-reaper) says, so an admitted charge is always backed and a fault never allocates; a thread block is two single pages mapped into an 8 KiB-aligned slot of a thread region the fork adds, as this kernel's stacks are, so no allocation on the fork is above order zero; `bootstrap` passes Fiasco's `kmemsize` option, computed by the pool plan that the kernel recomputes at boot, to give that allocator all of RAM but the regions `bootstrap` placed and the boot image, within the kernel's 1 GiB physical-memory window, where Fiasco's default is 6 per cent of RAM on 64-bit builds (`config.cpp`, `kmem_alloc.cpp`); the root budget, from which every other budget is carved, is a wall whose guarantee and cap are that pool ([design-stopgap.md](design-stopgap.md#kernel-memory-and-the-root-budget)) | the root budget is what Fiasco's allocator holds once Fiasco's own boot is done, less the page records and the thread region's tables, not every page left, and RAM beyond the window is unusable | M5, G6's many domains |
| spaces with their parents, created by any holder of `SPACES`, and sub-spaces | in full | modified: Fiasco tasks, constructed by the glue's installer from `erx_space_create`'s validated plan and never through Fiasco's factory, which is not built, with the parent and the wait for children's exit records from the C17 stop core shared with erXos's kernel | | M1, M5 (K27) |
| stops of spaces and threads, `CONTROL` stops, and exit records (K18) | in full | added: a list of each task's threads, which Fiasco's tasks lack, joined at a thread's creation under the task's lock; one run word per task holding the stop state and the count of its live threads, written only under the task's lock by the C17 stop core, which a thread enters at its creation and leaves at its death edge, before Fiasco's `unbind()`; one kill request per thread, carried by Fiasco's eager cross-CPU request, which ends its wait, marks it dying and raises it to the finishing priority; every return to user mode passes `erx_return_check` in Fiasco's common return path, where a killed thread dies through `Thread::do_kill` and a thread of a stopped task holds until its kill; the IRQ shortcut is off; a `CONTROL` stop sleeps the thread at that check, its registers kept, until `erx_thread_start`; the death edge that takes the count to zero posts the exit record to the fault gate, publishes `EXITED` and wakes every waiting stopper, once every child's record has been posted ([design-stopgap-scheduling.md](design-stopgap-scheduling.md#stop-and-exit)) | the count is of live threads, created to dead, where erXos's kernel counts the threads active inside calls, both zero exactly when no thread can act; finishing threads run on their own CPUs at the fixed finishing priority above every urgency, outside every quota, charged for the accounting to the `finishing_ns` of their own paths, as on erXos's kernel, but with no finishing share, so a stream of kills can hold a CPU's user threads back for as long as it lasts, and a dying lock holder may be helped as Fiasco helps any holder (**Differences that remain** below); a thread of a stopped space that reaches its return boundary before its kill holds there rather than dying at once, with the same observable contract | M1 (K18), M5 (K27) |
| emptying a stopped space's table, and deleting a tree of tasks | in full | added: the emptying of a stopped task's own table, in bounded parts, each slot cleared through the C17 capability core's `erx_cap_slot_clear`, shared with erXos's kernel; the deletion walk of a stopped task's tree, deleting each task below ([design-stopgap.md](design-stopgap.md#deletion)) | | M1 (the walk, run by a space's destroy), M5 (`erx_space_clear_caps`) |
| pauses of spaces, in their named states | erXos's kernel alone | | `erx_space_pause` fails with `ERX_ENOTSUP`; `Ctrl-Z` stops a job's Erlang commands, and the shell names the job's programs, which run on | track S, after M7 |
| memory objects (private, shared, contiguous and physical), private memory, ceilings, reserves, `erx_space_protect`, `erx_mem_grow` and `erx_mem_copy` | in full | added: a memory-object kernel object whose pages come from Fiasco's kernel allocator charged to the quota, a contiguous object's as one physical range and a physical object's from a resource's device memory; mappings inserted into the task's address space directly, without the mapping database, each attached to its object's reverse map; per-task mapping records from the same C17 planning core as erXos's kernel, with a deleted object's records kept so an access to them faults as `ERX_FAULT_DELETED`; the fault decision's populate results resolved in the kernel before any page-fault message; `erx_mem_copy` as an invocation that copies through Fiasco's kernel mapping of both objects' pages; every invocation's arguments in registers and UTCB words, with windows as erXos defines them ([Arguments and results](#arguments-and-results)) | | M1 (private and shared objects and kernel-made physical objects), M5; contiguous objects and physical objects from device resources with the resource rows' milestones |
| paged objects supplied whole and sealed: the file and code objects that programs run and map | in full | added: the memory-object kernel object with `erx_mem_supply` and `erx_mem_seal`: an object is mapped only once sealed and has an execute ceiling only when created with `ERX_MEM_CODE`, as [Copy-on-write children and copies of spaces](#copy-on-write-children-and-copies-of-spaces) defines | | track P, M6 |
| store tracking with `erx_mem_dirty` | erXos's kernel alone | | a file's `MAP_SHARED` mappings are the second tier's | track Q |
| copy-on-write children | erXos's kernel alone | | `erx_exec` copies a program's writable segments into private memory at load, and a writable private mapping of a file reads its range into private memory at the call | track Q |
| copies of spaces | erXos's kernel alone | | programs start by spawning; `fork` is the second tier's | track Q |
| JIT objects in JIT spaces | in full | added: the memory-object kernel object's JIT kind, with the rights of its kind ([Rights](#rights)), recording the task whose thread created it, a task created as a JIT space, and mapped writable at one address and executable at another only in that task | | M4 |
| no mapping writable and executable at once (K8) | in full | modified: a check in the address-space insertion path | | M1, M4 |
| no page executable through one mapping while writable through another (K8) | weaker | the same check, with an execute ceiling only on the boot image's slices, sealed code objects and JIT objects | it holds for the CPU and not for devices: the stopgap's drivers run with unconfined DMA | M4, M6 |
| threads, executors and workers, and the executor rule | in full | modified: Fiasco threads with the class and group added; the executor rule checked in the IPC path | | M1, M2 |
| faults to the fault gate | in full | modified: Fiasco's page-fault and exception paths hand every user-mode exception to `erx_fault_classify` and every memory fault to `erx_fault_decide`, which populates through Fiasco's translation-table insert or stops the thread and posts the fault record to the space's fault gate as a kernel-originated message with the fault label; Fiasco's per-thread pager and exception handler stay unset and the paths that would use them are not built, so no code in a space can redirect its faults ([design-stopgap.md](design-stopgap.md#faults-and-the-fault-of-the-root-task)) | | M1 |
| a fault of the root task, which has no fault gate (K31) | in full | modified: the root task has no pager; the kernel maps its whole image at start from the same startup plan that computes its charges, and a stray access reaches the kernel's crash path, which writes a crash record with cause `FAULT` and ends the machine | | M1 |
| the kernel's watchdog and the root task's halt (K31) | in full | added: `erx_watchdog_pet` as an invocation on the erXos platform object; the deadline checked at Fiasco's periodic tick; the crash record written to the console, since QEMU has no region that survives a reset; the end through the same firmware call as `erx_machine_end`; a stop of the root task's task by anything but `erx_machine_end` takes the same path | no board watchdog, since the stopgap runs on QEMU only | M1, M3 |
| IPC gates, open waits, calls with an implicit reply, deadlines, and messages in the UTCB | in full | modified: Fiasco's IPC gates and IPC paths, with absolute deadlines turned into Fiasco's timeouts and a dropped caller woken with `ERX_EDEAD`; Fiasco's UTCB, the same 1 KiB, with a receive by count turned into a receive window over the reserved slots | | M1 |
| no donation: a server runs on its own group's grant | in full | modified: Fiasco's IPC direct switch is not taken: `activate_ipc_partner` makes the receiver ready and switches to nothing, and the scheduler's own switch, which sets the CPU's scheduling context to the thread it picks, runs the server at its own priority and on its own group's grant from its first instruction ([design-stopgap-scheduling.md](design-stopgap-scheduling.md#server-urgency-and-charging)) | | M1 |
| groups in configurations C0 and C1: grants, quotas, urgency levels, park and wake with epochs, and shared areas | weaker | added: a group kernel object around the C17 scheduler core; the shared areas as Fiasco kernel-user memory; Fiasco's fixed-priority ready queues and dispatch, which call the core for resolution, charging and draws and never for a pick; the park protocol on Fiasco's spin lock, state writers and timeouts ([design-stopgap-scheduling.md](design-stopgap-scheduling.md#park-and-wake)) | charges are taken at every change of a CPU's scheduling context and at Fiasco's 1 ms periodic tick, and quota enforcement runs at the tick, so it is accurate to 1 ms per CPU per period ([design-scheduler.md](design-scheduler.md#compatibility-and-migration)) | M1 (C0), M2 (C1) |
| published urgency, deferred preemption, status words and idle-first wake placement (C2) | erXos's kernel alone | | | M8 |
| IRQ objects bound to threads or groups, fired by software and by lines | in full | modified: Fiasco's IRQ objects, with the binding to a group and the last delivery at release added | | M1, track P |
| MSI IRQ objects | erXos's kernel alone | | the stopgap's devices are virtio-mmio devices with ordinary interrupts | M9 |
| umtx | in full | added: wait and wake on task addresses, each word found by a walk of the task's page table, refused unless its page is RAM that Fiasco's kernel maps, and read through that mapping | | M1, track P |
| vCPU upcalls | in full | modified: Fiasco's vCPU interface in its kernel-mode build, with the state area in the thread's kernel-user memory, and every inherited path that enters, defers or resumes an upcall deciding through the C17 `erx_vcpu_step` shared with erXos's kernel: an upcall admits only an IRQ delivery, where Fiasco's `vcpu_async_ipc` admits any sender (`receiver.cpp`), so no message is received into the registers an upcall interrupts; a resume decides by the thread's queue, where Fiasco's tests the pending flag, which user mode can clear (`thread_object.cpp`); a resumed frame with a bit it may not hold stops the thread; the fault flags read as zero, executors refused, and umtx waits ended with `ERX_EINTR`; Fiasco reaches the area through its own kernel alias, unchanged; conformance tests on the stopgap send a message to an armed thread with events enabled, which its open wait receives and no upcall takes, and resume over a queued delivery whose pending flag user mode cleared, which enters the upcall again | | M5, track P |
| resources: device memory and interrupt lines | in full | added: a resource kernel object over the device memory and interrupt lines that `bootstrap` and the kernel derive from the device tree | | M6 |
| a PCIe bridge's windows, DMA windows and the IOMMU | erXos's kernel alone | | the stopgap's drivers drive virtio-mmio devices with unconfined DMA; the stopgap runs development builds only, which run trusted code | M9 |
| asynchronous errors | weaker | existing: Fiasco's handler, which counts each error per CPU and resumes (`thread-jdb.cpp`) | no containment: an error is counted, not contained as [Interrupts, time and entropy](#interrupts-time-and-entropy) describes; a documented difference with its tests | |
| the early console and the kernel log | in full | modified: Fiasco's own UART driver for the console port, written until the console's driver carves the UART from the root resource and at a panic or the machine's end, with Fiasco's own console output turned off once the root task starts and the UART's registers in the root resource; the kernel log as a ring the stopgap adds, written through `erx_log_escape` and read with `erx_log_read` | Fiasco's own start-up lines precede erXos's banner on the console (**Differences that remain** below) | M1, M3 |
| the time page and timers | in full | added: the time page as kernel memory mapped read-only, updated from Fiasco's clock; kernel deadlines as Fiasco's timeouts | | M1, M3 |
| entropy | in full | added: the C17 generator core over FreeBSD's ChaCha20 and the imported BLAKE3 (`kernel/crypto/`) behind a kernel object | | M1 |
| the trace ring and `erx_object_info` | in full | added: erXos's trace ring and inspection topics as kernel objects beside Fiasco's objects, recording the ABI file's trace event types | Fiasco's own trace buffer stays in its kernel debugger | M4 |
| deterministic mode | in full | added: with `erx.det=1` the stopgap starts no secondary CPU, seeds the generator with the fixed value, fixes the placement bases of the objects it adds, reads time only from the instruction-counted virtual counter and fixes the wall clock, as erXos's kernel does ([Deterministic mode](#deterministic-mode)) | Fiasco's own start-up lines are part of the transcript | M3 |
| the boot image, its validation, its slices and maps, and the banner | in full | modified: `bootstrap` is the first stage of the bootable file, finds the archive with `erx_boot_locate`, runs erXos's C17 `ERXPACK` validator, checks the kernel's file and finds the kernel and the root task in the image, there being no `sigma0` executable; the image's pages go to the root task as a module, which the kernel wraps in the boot image's object, so `erx_image_slice` and `erx_image_map` slice and map it as on erXos's kernel; `bootstrap` passes the boot image's flags and build identifier to the kernel, which prints erXos's banner after its own start-up lines and before it starts the root task | | M1, M3 |
| the machine page and its boot value | in full | added: the page, in the ABI file's layout, written by the kernel from the boot arguments `bootstrap` passes and from the two `/chosen` properties that name the boot slot, which the QEMU harness writes | | M6 |
| the device-secret page | in full | added: the page, in the ABI file's layout, with the status `no_key`, since the stopgap runs only on QEMU, where the platform has no key | no boot-only section: the key read is erXos's kernel's alone | M1, so the root task's root capabilities are the same on both kernels |
| ending the machine | in full | added: `erx_machine_end` as an invocation on an erXos platform object that calls Fiasco's firmware calls for power-off and reset; `ERX_END_TRIAL` fails with `ERX_ENOTSUP` | | M1 |
| the machine lease of a trial boot (K19) and the board's watchdog | erXos's kernel alone | | they come with M12, after erXos's kernel has replaced the stopgap; on the stopgap no lease is held and no board watchdog runs | M12 |

**What enters the tree.** One frozen, mutually consistent set, imported
once as erXos's code under `fiasco/` with an `ORIGIN.md` for each part
(repository, commit and the SHA-256 of what was imported): the Fiasco
kernel at commit `50bbe8a9`; Fiasco's `bootstrap` at `a4f4ad18`; from
`l4re-core` at `e2e2d5af`, `sigma0`, the `l4sys` headers and the libraries
those two link; `libfdt` at `5756062b`; and the `mk` build system at
`22cc26e5`, which builds them behind erXos's top-level build; and, from
`drivers-frst` at `6459d70997da1a2ad97775c8772b4a41284b0a9e`, only
the PL011 UART source, its required headers and build support that
`bootstrap` links. The UART subset keeps its MIT package licence and has
its own origin inventory; other `drivers-frst` drivers are excluded.
The kernel and its user-level parts must come from the same tree: a
snapshot user land and a newer kernel fail a boot-information layout check
([research](research-hierarchical-scheduling.md#fiasco-under-hvf)). None of
L4Re's user-level stack above `sigma0` enters: no `moe`, no `ned`, no L4Re
libraries for applications. The kernel is built to run in kernel mode
without its hypervisor support (`CONFIG_CPU_VIRT` off); the hypervisor
build does not boot under HVF.

**The seam.** `liberx` is the only code that issues kernel calls, and its
`fiasco` backend is the only code that includes an `l4sys` header or
executes Fiasco's system-call instruction sequence; a chokepoint check
enforces both ([Chokepoint checks](#chokepoint-checks)). The root task's
`liberx`, the runtimes and the programs are linked against `liberx` and
run unchanged on either kernel.

The C++ that integrates with Fiasco (the kernel objects it adds, hooks in its
scheduler and IPC paths) is thin; the decisions behind it (the scheduler
core, the planning of mappings, budget arithmetic, the park state
machine, the ABI decoders, the boot-image
validator) are C17 files shared with erXos's kernel and built for the host.
The construction rules (the stack proof, `musttail`-only recursion, the
chokepoint checks, generated register access) bind that C17 code;
Fiasco's inherited C++ keeps its own style and is exempt.

**Differences that remain.** Besides the weaker guarantees of the table,
each documented, tested, and gone when erXos's kernel replaces the
stopgap:

* user mode reads the performance counters directly, for profiling, and
  they count every thread and kernel mode, so a domain can observe
  another's activity; erXos's kernel leaves them disabled
  ([design-stopgap.md](design-stopgap.md#interfaces)). Development builds
  run trusted code only, and a confined profiling interface replaces
  this access (`TODO.md`).

* `sigma0`'s task remains, the task Fiasco's code takes for the root of
  physical memory; no thread runs in it, nothing can send to it, and the
  boot image carries no executable for it. Fiasco's memory mapping
  database, which its boot rooted there, is not built: the only mappings
  are erXos's mapping records ([design-stopgap.md](design-stopgap.md#transport)).
  It pages nothing of the
  root task, which has no pager; the kernel maps the root task's whole
  image at start from the same startup plan that computes its charges
  ([design-stopgap.md](design-stopgap.md#transport)).
* Fiasco prints its own start-up lines on the console before erXos's
  banner. The slice's transcript tests and M7's comparison of the two
  kernels start at the banner, which both print, so those lines never
  count as a difference; in deterministic mode they are part of a
  transcript that stays byte-identical from run to run.
* Fiasco's kernel debugger is built into development builds only, on the
  console port, which it shares with the console's driver there.
* Finishing on the fork has no share: a killed thread runs at the fixed
  finishing priority above every user urgency on its own CPU, outside
  every quota, until its call is done, so a stream of kills homed on one
  CPU holds that CPU's user threads back, the root task's petting thread
  among them, for as long as the stream lasts. The bound is the stopped
  spaces' remaining work, which their budgets paid for. erXos's kernel
  bounds it with the finishing share; on the fork it is a stopgap
  residual, acceptable because development builds run trusted code
  ([design-stopgap-scheduling.md](design-stopgap-scheduling.md#security),
  `TODO.md`).
* The stopgap is never hardened: development builds run trusted code only,
  and the security closure milestone is reached on erXos's kernel. Bugs
  found in the fork are fixed like any other. Its designs commit to what
  M1 needs and its tests check, for trusted workloads: no memory error,
  no deadlock, every stop finishing, the interface's results and exact
  accounting; latency bounds, fairness and progress against hostile load
  are erXos's kernel's.

**Licences.** Fiasco, `bootstrap`, `l4re-core`'s `sigma0` and `l4sys`, and
`mk` declare MIT in their `LICENSE.spdx` files; `libfdt`'s declares MIT
for its packaging and `GPL-2.0-or-later OR BSD-2-Clause` for the library
in `lib/contrib`, used under BSD-2-Clause. The fork excludes Fiasco's
GPL-licensed `src/lib/regex`, `src/lib/simple_malloc` and `src/lib/gcov`,
the LGPL `perfctr` code and the Qualcomm board support, whose eight files
under `src/kern/arm/bsp/qcom/` carry GPL-2.0 headers, and configures out
the kernel-debugger features that need them. Two GPL-2.0 files stay,
because the kernel cannot be built without them: `src/kern/kobject_rpc.h`,
which `task.cpp`, `ipc_gate.cpp`, `irq.cpp`, `icu_helper.cpp`,
`pi_mutex.cpp` and `arm/smc_user.cpp` include, and
`src/kern/jdb_object.cpp`, part of the kernel debugger of development
builds, whose disassembler, capstone, is BSD-3-Clause-Attribution (the
licences as the files' own headers and the fork's `LICENSE.spdx` state
them at `50bbe8a9`). So every stopgap build carries GPL code, and nothing
built on the stopgap is distributed outside the project, in source or
binary form, until erXos's kernel replaces it, as the rule for stopgaps
requires. erXos's own code is BSD-2-Clause; the project's stopgap
distribution restriction also applies to its dependencies. `l4re-core`
contains GPL-licensed libraries
(its minimal C and C++ support among them); the import records the link
closure of `bootstrap` and `sigma0` and the licence of each library in it.

erXos's kernel translates or copies code only from Fiasco files whose
effective licence is permissive and whose provenance shows nothing else, a
rule decided provisionally, for the user to confirm
([design.md](design.md#risks-and-open-questions)). A file takes the
licence that Fiasco's `LICENSE.spdx` declares for its package, MIT for the
kernel at `50bbe8a9`, unless its own notice says otherwise, and the import
records each translated file's upstream history: GPL-2.0 counts a
translation as a modification, so a file whose history shows GPL code is
not translated, whatever its header says. erXos's kernel needs nothing
from the two GPL-2.0 files, since its dispatch is generated and it has no
kernel debugger, and the import's licence scan lists every file whose
notice is not permissive, so a review can see that no erXos file derives
from one. Code that erXos's kernel translates from a permissive Fiasco file
keeps Fiasco's notice: each such file carries
`SPDX-License-Identifier: BSD-2-Clause AND MIT`, since it
holds erXos's own code and Fiasco's, with Kernkonzept's copyright line and
a line naming the Fiasco file and commit it derives from;
`kernel/NOTICE-fiasco` holds the MIT text, and the dependency table of
[design.md](design.md#dependencies) records it.

**Replacing it.** erXos's kernel replaces the stopgap once it runs the
same slice. The conformance suite, run identically on both kernels for
every feature the stopgap carries, the slice's transcript tests, the
oracle and the scheduler and messaging benchmarks are compared, and every
difference is a bug in erXos's kernel, a documented improvement with a
test, or a bug in the stopgap recorded as such ([plan.md](plan.md)); what
the stopgap leaves out is tested on erXos's kernel alone.

## Interfaces

### Calling convention and status codes

A kernel call is the architecture's system-call trap with the call number
and up to six arguments in registers that the architecture's ABI file
assigns ([The ABI file](#the-abi-file),
[design-arch-aarch64.md](design-arch-aarch64.md#system-call-trap)). On
return the first result register holds an `erx_status_t`, zero or a
negative code, and the next two hold up to two results; every other
register is preserved. An IPC call returns its message's words and items
in the caller's UTCB ([Messages, gates and IRQ
objects](#messages-gates-and-irq-objects)), and so does every other call
whose results do not fit two registers, such as `erx_cap_pass`; a call
that returns bulk bytes, and changes nothing else, writes them into a
memory window the caller names ([Arguments and
results](#arguments-and-results)). No argument and no result is a user
address the kernel dereferences. Status codes form a closed set, defined
in the ABI file:

| Code | Meaning |
| --- | --- |
| `ERX_OK` (0) | success |
| `ERX_EINVAL` | a malformed argument: alignment, range, flags, writable with executable, a boot-image entry that is not an executable; the caller's own space for a pause, a resume or a copy; a resume, a quiesce or a copy naming a ticket that is not held; emptying the table of a space that has not stopped |
| `ERX_ESTALE` | no such slot, or a stale generation; the object a thread waited on was deleted or released; a mapping into a space or a DMA window that is being destroyed; a memory window whose object was deleted during the call |
| `ERX_ETYPE` | the capability names an object of another type; a call the caller's thread class may not make in that form (`erx_park` or `erx_group_take_ready` from a worker); a gate or IRQ object bound to an executor, or an executor armed for upcalls; a parent of copy-on-write that is not immutable; a memory window on physical memory with device attributes or on a JIT object; a growth or a store report of an object that is not a shared object |
| `ERX_ERIGHTS` | the capability lacks a right; a protection above a mapping's ceiling; a write to a sealed object; a slice that would include a system file |
| `ERX_ERANGE` | an address, offset or memory window outside its space, object or resource; a hole met by a part of `erx_space_protect`, the parts before it applied |
| `ERX_ENOMEM` | the budget's cap, the room of its ancestors, or physical memory cannot cover what the call needs |
| `ERX_ELIMIT` | a count limit: capabilities, slots a receive reserves, items a message carries, mappings, threads, holds on a space, executors per group, group depth, space depth, MSIs; object-identity or mutable-record sequence exhaustion |
| `ERX_EBUSY` | a resource in use: a line with an IRQ object, a stream with a window, a register page with an MMIO object, an executor for a group whose executors belong to another space that has not stopped, a paged object not yet sealed, a seal of an object that has writers; a copy of a space whose source is not quiesced |
| `ERX_ETIMEDOUT` | the deadline passed |
| `ERX_EFAULT` | a umtx word's address that no valid user-readable translation of the caller's space maps, or whose translation maps a page the kernel's direct map does not cover, found before the call changed anything, so touching the word and repeating the call is safe ([Umtx](#umtx)) |
| `ERX_EEXIST` | the range is in use; a copy's target that is not empty when the copy starts, or gains a mapping or a capability where the copy would place its own |
| `ERX_ENOTSUP` | an unknown call; an image built for another ABI version; a copy of a space that maps a JIT object; `ERX_END_TRIAL` while the boot value is `unknown` ([Console, log and panic](#console-log-and-panic)); on the stopgap, a call it leaves out, such as `erx_space_pause` ([The current implementation](#the-current-implementation-the-modified-fiasco)) |
| `ERX_EWOULDBLOCK` | an executor made a call that would wait ([design-scheduler.md](design-scheduler.md#executor-class-enforcement)) |
| `ERX_ENOCALLER` | a reply with no caller to receive it |
| `ERX_EDEAD` | the peer of a call, or the thread a sender was queued at, died or its space stopped; the caller was dropped by a server that took another call, or its server died; a stopped space takes no thread and no child; a copy whose source or target stopped or was destroyed; the IOMMU behind a window has failed |
| `ERX_EINTR` | the thread was stopped while a call of its own waited, or an armed thread's umtx wait took an event; the call may be repeated |

### Kernel calls

The calls, as the ABI file declares them. A capability argument names the
rights it needs in parentheses; `ERX_CAP_SELF` names the caller's space
and `ERX_CAP_NULL` no object. Sizes are bytes; times are absolute
monotonic nanoseconds, with `ERX_TIME_NEVER` = 2^64 - 1, and a time
already passed means not waiting. Every call may also return the
dispatch's errors (`ERX_ENOTSUP`, `ERX_EWOULDBLOCK`, the capability
errors). Calls that may wait are marked with the executor rule.

| Area | Calls | Notes |
| --- | --- | --- |
| capabilities | `erx_cap_dup(c (DUP), mask)`, `erx_cap_close(c)`, `erx_object_destroy(c (DESTROY))`, `erx_cap_pass(from (CAPS), to (CAPS), n)`, `erx_object_info(c, topic, index, window)` | every copy is a slot of its own; a close removes one slot, and a deletion every slot and mapping, in parts ([Closing and deleting](#closing-and-deleting)); `erx_cap_pass` passes at most four from one table to another, its items and their results in the caller's UTCB, as a rendezvous does; into a space the caller created the pass sets do not bind, except that a space's capability goes with `INSPECT` alone and `CODE` never goes (K17, K24, [Passing capabilities](#passing-capabilities)); `erx_object_info` writes into a memory window ([Arguments and results](#arguments-and-results)) |
| budgets | `erx_budget_create(parent (CARVE), kind, guarantee, cap)`, `erx_budget_resize(budget (DESTROY), guarantee, cap)`, `erx_budget_watch(budget (ALLOC), irq (TRIGGER) or ERX_CAP_NULL, threshold)` | a child's guarantee is charged to its parent, which may borrow for it, and its capability carries `DESTROY`; its kind, a wall whose cap stays equal to its guarantee or an elastic budget, is fixed at carving; a cap below the guarantee, or for a wall other than it, fails with `ERX_EINVAL`, a parent at depth `ERX_BUDGET_DEPTH_MAX - 1` with `ERX_ELIMIT`; the carver, or whoever it passed `DESTROY` to, resizes both values in one step, a shrink of the guarantee never failing and a cap below the spending refusing every charge that would raise the spending until it falls; a watch triggers its IRQ object once when the spending reaches the threshold, at once if it is already there, and an IRQ object is the watch of one budget; destroying a budget deletes every object charged to it and every budget carved from it, and returns its guarantee and its borrowing to its parent ([Budgets](#budgets)) |
| spaces | `erx_space_create(budget (ALLOC, SPACES), parent (CAPS), fault (SERVE), label, flags, cap_limit)`, `erx_space_stop(space (STOP), status)` (executor: refuse), `erx_space_pause(space (STOP))`, which returns the hold's ticket, `erx_space_resume(space (STOP), ticket)`, `erx_space_clear_caps(space (CAPS))`, `erx_space_quiesce(space (STOP), ticket)` (executor: refuse), `erx_space_copy(from (MAP, STOP), to (MAP, CAPS), ticket)` | the parent, the fault gate and the label are fixed at creation, and the parent is the caller's own space or one below it; `ERX_SPACE_JIT` needs `CODE` on the budget or a JIT space as the caller's own ([Creating spaces](#creating-spaces)); `ERX_CAP_SELF` carries `STOP`; stopping walks the spaces below and kills their threads, each finishing on its own CPU, charged to its own path's `finishing_ns`, and waits for the tree's exit record ([Execution model and locking](#execution-model-and-locking)); `erx_space_copy` is a sub-space creator's, for `fork`; pausing, resuming, quiescing and copying refuse the caller's own space, a hold is a ticket that names what runs under it, and a hold keeps a space's threads only from returning to user mode; `erx_space_clear_caps` empties the space's own table, `erx_object_destroy` on a space deletes its tree, and emptying a table and copying a space proceed in parts; quiescing waits, under one hold, until the space's threads have finished the calls they were in, and a copy under that hold requires that and waits for nothing |
| threads | `erx_thread_create(budget (ALLOC), space (THREADS), group (ATTACH), class)`, with its starting registers in the caller's UTCB, `erx_thread_start`, `erx_thread_stop`, `erx_thread_read(thread (CONTROL), set)`, `erx_thread_write(thread (CONTROL), set)`, each moving one register set through the caller's UTCB, `erx_thread_set_affinity`, `erx_thread_set_urgency` (thread (CONFIGURE)), `erx_thread_exit()` | `erx_thread_stop` returns once the thread's home CPU has applied the stop, without waiting for the thread to reach it, and `erx_thread_create` once any handover of its executor slot has been applied, each by a bounded spin that never waits ([design-scheduler.md](design-scheduler.md#park-and-wake)); registers are read and written only while the thread is stopped, and `erx_thread_read` and `erx_thread_write` refuse one that has not stopped yet (`ERX_EBUSY`) ([Threads and faults](#threads-and-faults)) |
| vCPU | `erx_vcpu_control(thread (CONFIGURE), flags)`, `erx_vcpu_resume()` | an executor cannot be armed ([vCPU upcalls](#vcpu-upcalls)) |
| groups | `erx_group_create(budget (ALLOC), parent (CONFIGURE))` returning group, control and status capabilities, with the grant read from the caller's UTCB, `erx_group_configure(group (CONFIGURE))`, `erx_group_info(group (INSPECT))`, `erx_group_take_ready(max)` taking at most `ERX_MSG_WORDS` (63) labels into the caller's UTCB, `erx_park(group_epoch, slot_epoch, deadline)` (executor: allow), `erx_executor_wake(slot)`, `erx_yield` | [design-scheduler.md](design-scheduler.md#kernel-calls) |
| memory | `erx_mem_create(budget (ALLOC), size, flags)`, `erx_mem_create_contiguous(budget (ALLOC), resource (CARVE), size, limit)`, `erx_mem_create_physical(budget (ALLOC), resource (CARVE), range, attr)`, `erx_mem_dma_addr(mem (PHYS), offset)`, `erx_vm_reserve`, `erx_vm_commit`, `erx_vm_decommit`, `erx_vm_release` (space (MAP)), `erx_space_protect(space (MAP), addr, size, prot)`, `erx_vm_map(space (MAP), addr, size, mem (MAP), offset, prot)`, `erx_image_slice(budget (ALLOC), image (CARVE), first, count)`, `erx_image_map(space (MAP), slice (MAP), entry)`, `erx_mem_create_paged(budget (ALLOC, and CODE with ERX_MEM_CODE), size, flags)`, `erx_mem_supply(mem (SUPPLY), offset, src (READ), src_offset, len)`, `erx_mem_seal(mem (SUPPLY))`, `erx_mem_grow(mem (SUPPLY), size)`, `erx_mem_dirty(mem (SUPPLY), offset, npages)`, `erx_mem_child(parent (READ, CHILD), budget (ALLOC), offset, size)`, `erx_mem_own(child (WRITE), offset, size)`, `erx_mem_copy(dst (WRITE), dst_offset, src (READ), src_offset, len)` | none waits; range calls, supplying, taking ownership and copying proceed in parts; `ERX_MEM_JIT`; `ERX_MEM_INHERIT` lets a fork's copy share a shared object ([Copy-on-write children and copies of spaces](#copy-on-write-children-and-copies-of-spaces)); contiguous memory needs the resource entry of the unconfined device it is for; a paged object maps only once sealed; a sealed object takes no write; growth and store reports are a shared object's, and `SUPPLY`, which no pass between peers carries, is its manager's ([Memory](#memory), [Virtual memory](#virtual-memory)); a mapping keeps its object until it is unmapped or the object is deleted, and `erx_space_protect` moves its protection only beneath its ceiling (K4); a supply or a copy fails with `ERX_ESTALE` once an object it reads or writes is deleted, never with a fault ([Arguments and results](#arguments-and-results)) |
| IPC | `erx_gate_create(budget (ALLOC))`, `erx_gate_bind(gate (SERVE), thread (CONFIGURE), label)`, `erx_ipc_call(gate (CALL), tag, send_by, reply_by)`, `erx_ipc_send(gate (CALL), tag, send_by)`, `erx_ipc_wait(wait_by)`, `erx_ipc_reply_wait(tag, wait_by)`, `erx_ipc_reply(tag)` | every call but the first two and `erx_ipc_reply` may wait (executor: refuse); messages of up to 63 words and four items in the UTCB; a receive returns the tag and the label ([IPC gates](#ipc-gates)) |
| IRQ objects | `erx_irq_create(budget (ALLOC), resource (CARVE) or ERX_CAP_NULL, kind, selector)`, `erx_irq_bind(irq (BIND), thread (CONFIGURE) or group (SIGNAL), label)`, `erx_irq_trigger(irq (TRIGGER))`, `erx_irq_ack(irq (ACK))`, `erx_irq_route(irq (CONFIGURE), cpu)` | none waits; an MSI's creation returns its doorbell address and data ([IRQ objects](#irq-objects)) |
| umtx | `erx_umtx_wait(addr, expected, deadline)` (executor: allow on private memory), `erx_umtx_wake(addr, count)` | [Umtx](#umtx) |
| resources and DMA | `erx_resource_carve(budget (ALLOC), resource (CARVE), kind, selector)`, `erx_dma_create(resource (CARVE), budget (ALLOC))`, `erx_dma_map(window (MAP), iova, size, mem (MAP), offset, prot)`, `erx_dma_unmap(window (MAP), iova, size)`, `erx_dma_bind(window (BIND), irq (TRIGGER))` | none waits |
| log and trace | `erx_debug_log(len)`, its text in the caller's UTCB, `erx_log_read(res (TRACE), cursor, window)`, `erx_trace_read(res (TRACE), cpu, cursor, window)` | none waits; each reader writes whole records into its window and returns the next cursor and the count of records lost ([Console, log and panic](#console-log-and-panic), [Trace ring](#trace-ring)) |
| time and entropy | `erx_time_set_wall(time_page (WRITE), wall_ns)`, `erx_entropy_read(len)`, `erx_entropy_add(res (CARVE), len, flags)`, their bytes in the caller's UTCB | crediting needs `ENTROPY` |
| machine | `erx_machine_end(res (POWER), how)`, `erx_watchdog_pet(res (POWER))` | `how` is `ERX_END_OFF`, `ERX_END_RESET`, `ERX_END_PANIC` or `ERX_END_TRIAL`; the end returns only to fail `ERX_END_TRIAL` with `ERX_ENOTSUP`; a pet never waits and moves the deadline `D` seconds ahead ([The watchdog](#the-watchdog)) |

### The ABI file

`abi/erx_abi.txt` is the one source of the kernel interface and of every
fixed binary layout that is the same on every architecture: a
declarative, ASCII, line-oriented file. Each line is a keyword and its
fields; indented lines belong to the declaration above them; `#` starts a
comment. It explicitly includes the inspection and service fragments
under `abi/`, which use the same shared types and qualified identifier namespace.
Includes are resolved as one declaration set; cycles, duplicate names and
paths outside `abi/` fail generation
([design-generation.md](design-generation.md#sources-and-outputs)). Each architecture adds one file in the same grammar,
`abi/arch/<arch>.txt`, with what differs between architectures: the
registers of the system-call convention, the layouts of the user frame and
of the saved thread state, and the in-memory structures its MMU and IOMMU
read ([design-arch-aarch64.md](design-arch-aarch64.md#the-abi-file-for-aarch64)
shows AArch64's). The generator reads the neutral file and the file of the
architecture it builds for, and refuses a name declared in both.

```text
abi 1
include inspection.txt
limit copy_max u32 1048576
limit group_executors u32 64
status wouldblock -14 "an executor made a call that would wait"
bytes erx_pack_magic 8 value 4552585041434b00
layout erx_pack_header 2 wire_le 8 96
  field magic erx_pack_magic 0
  field version u32 8
  field flags u32 12
  field total_size u64 16
  field nentries u32 24
  field entry_size u32 28
  field entries_off u64 32
  field strings_off u64 40
  field strings_size u32 48
  field root_entry u32 52
  field build_id u8 56 count 8
  field index_hash u8 64 count 32
```

The [declaration grammar](design-abi.md#source-grammar) defines every
form, the validated model, numeric assignment and reader contracts. A
layout declaration states representation; its reader also declares field
ranges, fixed values and table relationships before exposing a validated
view. The example above shows a layout, not the archive's entire check.

It declares the calls (number, name, whether it may wait, its bound per
part, executor rule, the budget it charges, arguments with types and
rights, the argument whose existence lock the dispatch holds, marked
`exists`, results, which arguments are memory windows and whether each
is read or written, and whether the call only reads, marked `reads`, the
one kind of call that may write a window, since it changes nothing but
that window's bytes and the caller's UTCB and registers ([Arguments and
results](#arguments-and-results)), the layout in the UTCB of each argument
or result that does not fit a register), the status codes, the capability rights, each
object type's rights, default rights and pass set, the well-known
capabilities, the trace event types, the limits, the inspection topics,
the fault kinds with the POSIX signal by which a program's end reports
each, the signal names and default actions that `liberx` and the program
protocol share, the `errno` table and contextual status/error translations,
the frame profiles of the file and program protocols, and
every structure with a fixed layout that crosses a boundary: the UTCB, the
message tag and typed item, the vCPU state area, the fault record, the
register sets of `erx_thread_read` and `erx_thread_write`, the grant, the shared
areas of groups, image manifests, the time page, the trace record, the
`ERXPACK` header and entry, the boot information page, the machine page,
the device-secret page with its status, the labels the device and sealing
secrets are derived under, the crash record, and the virtio rings that drivers
share with their devices. The inspection fragment declares the semantic
record/path/field types, units, bounds, reporter categories and visibility
requirements; service fragments declare operations, authority sources and
request/reply bounds. They reference these shared declarations instead of
copying them. The source marks each layout that is a
sequence-counted record, the capability slot and the trace record among
them ([Sequence-counted records](#sequence-counted-records)). An
architecture's file declares the registers of its call convention, the
layouts of its user frame and saved thread state, and the in-memory
structures its MMU and IOMMU read: translation-table descriptors, which
the CPU and the IOMMU share, and the IOMMU's stream table entries, context
descriptors and queue entries.

The message-tag schema distinguishes the bits a caller writes from those
only the kernel sets on a receive, and generates the check that refuses
the latter on every user IPC input together with the receiver's decoder.
Each sequence-counted layout also declares its terminal retirement,
reader exhaustion result and permitted recovery transition.

`tools/gen_abi.rb` generates from it: `include/erx/abi.h` with every
constant and layout, each layout pinned with `_Static_assert` on its size
and field offsets, a get and set function for every bit range, so no code
packs descriptor bits by hand, and for each field of a sequence-counted
record the one acquire load and the one release store its readers and its
writer use; the kernel's decoders, its handler table and its executor-rule
table; the prototypes of the handlers (`erx_sys_<name>`); `liberx`'s call
wrappers for each backend (the `erx` backend's trap stubs for each
architecture; the declarations the `fiasco` and `hosted` backends
implement); the Erlang header with the status codes, rights, limits and
fault kinds; and a Ruby module with the layouts the packer and the host
tool write and read. The generator fails on a duplicate name or number, an
unknown keyword or type, a capability argument without a type and rights,
a right outside its type's set, a type without a pass set or with one
outside its rights, a pointer type, which the grammar does not have, a
memory window with a maximum above `copy_max`, a call without a declared
bound or wait property, a call without an executor rule, a call that
does not wait and refuses executors, a waiting call with a memory window,
a written window on a call not marked `reads`, a UTCB layout longer than
the 63 message words, two arguments or two results sharing a UTCB word, a
call whose register parameters need more than six argument words or two
result words, a misaligned field, and bit ranges that overlap
or leave their field. The kernel, every `liberx` backend, the runtimes and
the Erlang code therefore agree by construction, and every list the
dispatch depends on (calls, rights, types, pass sets, charged budgets,
executor rules) is closed by the generator rather than kept complete by
hand.
Generated files are ASCII and readable, are checked in, and nothing edits
them by hand: the drift check covers them. The same declarations produce
typed log/trace emitters and decoders, diagnostic names, API reference
tables and parser test/fuzz scaffolding under
[Generated interfaces and representations](design-generation.md). Emitter
projections select release/development fields explicitly, and every
untrusted string still passes through the log sink's escaper. The
generator's own output never supplies its sole expected test answers.

### Hardware register sources

Device registers and system registers each have one checked-in source, and
Ruby generators produce every accessor from it. A drift check, part of
`make check`, regenerates every generated file into a scratch directory and
fails the build when a checked-in one differs.

**Device registers** are described in CMSIS-SVD files under `hw/svd/`, one
per device that erXos code touches, written by erXos from the devices'
specifications: each platform's UARTs, interrupt controllers, MSI frames,
real-time clock and IOMMU, which the bindings list with the specification
each follows
([design-arch-aarch64.md](design-arch-aarch64.md#hardware-register-sources),
[design-platforms.md](design-platforms.md#the-devices-the-kernel-drives)),
and virtio-mmio (the OASIS virtio specification), for drivers through
`liberx`. `tools/gen_hw.rb` reads them with REXML, the XML parser Ruby
ships as a bundled gem (REXML 3.4.4 with Ruby 4.0.7, BSD-2-Clause, checked
on the development host on 2026-10-29), and emits one C header per device:

* an accessor for every register, taking the device's `erx_mmio_t` base,
  with the access width the file declares, and no other way to reach the
  register;
* for each field, an enum of its enumerated values and get and set
  functions that shift and mask;
* a read-modify-write function only for a register whose reads have no side
  effect: a register or field with a `readAction` gets read and write
  accessors only, and a field whose `modifiedWriteValues` is `oneToClear`
  gets a clear function instead of a setter;
* the access sequences a device's specification prescribes and SVD cannot
  express (such as an interrupt controller's wake handshake or an IOMMU's
  enable handshake, which the binding lists), declared in the device's
  `vendorExtensions` element in erXos's own
  namespace and emitted as one function per sequence, with its barriers.

The generator refuses a register outside its address block, overlapping
fields, a field beyond its register's width, an enumerated value wider than
its field, a duplicate name, and an unknown element in erXos's namespace.

**System registers** are described in `hw/sysreg/<arch>.json`, one
checked-in file per architecture holding every system register erXos code
reads or writes: its encoding, width and fields as the architecture's
machine-readable specification gives them, and erXos's attributes beside
them: whether a read has a side effect, such as acknowledging an
interrupt, and the synchronisation a write needs. A per-architecture
extractor makes the file from the architecture's published data; the
binding names AArch64's source, its version and its licence
([design-arch-aarch64.md](design-arch-aarch64.md#hardware-register-sources)).
`tools/gen_hw.rb` reads only the
checked-in file and emits an inline accessor per register, field functions
as for devices, and no read-modify-write function for a register whose
reads have a side effect. These accessors and the named barrier and
maintenance helpers are the only places system-register instructions
appear. `make check-sysreg` extracts again and compares, so a hand-edited
fact fails it.

Both sources bind erXos's kernel and the C17 code erXos adds to the
stopgap; Fiasco's inherited C++ keeps its own register code.

### Configuration

The kernel command line (`/chosen/bootargs`) is parsed once at boot, up to
2,048 bytes; a longer one, as firmware that prepends its own text can
make, is cut at the last whole word within that length, and the boot
reports the cut. The kernel takes the keys below; a malformed value of
one of them is reported on the early console, by its key alone, and the
default used. Words are separated by spaces, tabs and newlines. An `erx.`
word that names none of these keys the kernel reports itself in the kernel
log ([Console, log and panic](#console-log-and-panic)), once the log's ring
exists, and the boot goes on. Each such word gets one warning record: a
fixed prefix the kernel wrote, then the key up to any `=`, at most 64 bytes
of it, since a value may hold anything. The key is firmware text, so
untrusted, and enters the log only through `erx_log_escape`. The kernel
reports at most 8 words and then one record counting the rest (both
estimates), so a long command line crowds neither the log nor the early
console, on whose time a trial's watchdog margin depends. Every other word
the kernel ignores, unreported. Nothing outside the kernel reads the command
line: the machine page holds none of it, and the system domain reads no boot
argument
([design-system.md](design-system.md#interfaces)). Sizes are
decimal with an optional `K`, `M` or `G` suffix, parsed with checked
arithmetic.

| Key | Meaning | Default |
| --- | --- | --- |
| `erx.det=1` | deterministic mode; a release build refuses it and stops | off |
| `erx.trial_deadline=S` | on a trial boot, seconds until the machine lease resets the machine, from 120 to 3,600, so a trial always leaves the 60 s a commit needs ([design-storage.md](design-storage.md#system-updates)) | 300, an estimate of a boot, the health checks and the commit with margin |
| `erx.dma_pool=SIZE` | the contiguous pool, from the lowest RAM, for unconfined devices' DMA memory ([DMA and the IOMMU](#dma-and-the-iommu)) | 32M, an estimate that each board port revises |
| `erx.cpus=N` | start at most `N` CPUs | every CPU in the device tree |
| `erx.sched=` | the scheduler's configuration cap ([design-scheduler.md](design-scheduler.md#configuration)) | `c2` |
| `erx.panic=halt`, `reset`, `off` | the end of a panic, and of the root task's fault, halt or missed watchdog deadline ([The root task](#the-root-task)); `reset` while a machine lease is held | `halt` in development builds, `reset` in release builds |
| `erx.watchdog=P,D,B` | the watchdog's period, deadline and boot deadline in seconds, which the machine page carries: the root task pets every `P` seconds, a deadline `D` seconds after a pet that passes without the next ends the machine, and a root task that has not pet within `B` seconds of its start ends it the same way; `P` from 1 to 60, `D` from `2P` to 600 and `B` from `D` to 600 ([The watchdog](#the-watchdog)) | `1,5,60` |

The boot image carries the build's flags: `ERX_PACK_DEVELOPMENT`, which
puts `development build: trusted code only` in the banner, and
`ERX_PACK_UNCONFINED_DMA`, which lets a release build create memory for
unconfined devices.

### Interaction with other subsystems

* **The scheduler** ([design-scheduler.md](design-scheduler.md)) is part of
  the kernel: its core decides, and the kernel's effect layer switches,
  programs timers and posts requests.
* **Runtimes** ([design-runtime.md](design-runtime.md)) reach the kernel
  only through `liberx`: memory, groups, park and wake, IRQ objects, umtx
  waits, time, entropy, and for workers, IPC gates and vCPU upcalls.
  Connections, channels and pipes are built above the kernel from memory
  objects and IRQ objects ([design-domains.md](design-domains.md#connections),
  [design-programs.md](design-programs.md#the-channel),
  [design-pipes.md](design-pipes.md)); the kernel knows nothing of frames.
* **The system domain** ([design-system.md](design-system.md)) is the
  root task: it holds the authority the kernel hands out at boot, pets the
  watchdog, and through the domain library in its `liberx` creates every
  domain's space, budget, groups and first thread, gives each its
  capabilities and devices, receives every domain's fault and exit
  records, and destroys the own budget of every domain that ends, and its
  outer budget once no one else needs it ([Budgets](#budgets)). It
  installs no gate of one domain in another, so no capability passes
  between two domains ([Rights](#rights)); within a domain's tree, spaces
  that share a gate pass capabilities at a rendezvous within the pass
  sets, and a domain that holds `SPACES` creates and serves its own
  sub-spaces, a session its programs' among them ([Creating
  spaces](#creating-spaces)).
* **The PCIe enumerator** ([design-system.md](design-system.md#devices)),
  an Erlang process in the PCIe domain, owns PCIe's configuration
  space through an ordinary register window; the kernel gives it nothing
  PCIe-specific.
* **The live machine** ([design-live.md](design-live.md)) gets the kernel
  log, the trace ring and the inspection topics of every object; its
  console and host-link services reach their UARTs through their drivers,
  never through the kernel
  ([Console, log and panic](#console-log-and-panic)).

## Compatibility and migration

Until a release promises compatibility, nothing the kernel defines owes
anything to its own earlier forms. A change to a call, a right, a status
code or a layout replaces the old form outright and is a new
`ERX_ABI_VERSION`: the generator rebuilds every side of the interface
from `abi/erx_abi.txt` at once (the kernel, `liberx`, the system domain's
services and the runtimes), and no shim, second decoder or reader for an
earlier version exists. Every format the kernel owns carries a version so
that a mismatch fails loudly where it is used: the ABI version in image
manifests and in the boot information page, `ERXPACK`'s version in the
boot image, the layout versions of the ABI file. A runtime or service
built for another ABI version is refused by `erx_image_map` with
`ERX_ENOTSUP`, and a boot image of another `ERXPACK` version by the boot
validator, each with a diagnostic and never misread. Nothing migrates:
the kernel keeps no state across boots.

Moving from the stopgap to erXos's kernel changes nothing above `liberx`:
the same boot image, built for the other kernel, boots the same root
task and runtimes. The replacement gate of
[The current implementation](#the-current-implementation-the-modified-fiasco)
decides when.

## Failure handling, diagnostics and debuggability

| Failure | Detection | State left | Who cleans up | What the user sees |
| --- | --- | --- | --- | --- |
| A malformed call | the generated decoder | nothing changed | none needed | the status code; a counter on the space |
| A budget cannot pay | the charging funnel | nothing changed | none needed | `ERX_ENOMEM` |
| A thread faults | the fault classifier | the thread stopped, its record kept | the system domain ends the domain, keeping no space of it: the fault record and the dump in the domain's crash area carry what inspection needs | the fault record, in the inspector and the log |
| A domain is ended, or ends itself | `erx_space_stop` | its threads and those of every space below it dead, finished at the finishing level within each CPU's share; their exit records on their fault gates, the domain's last; objects charged to its outer budget, which others map, stay | the system domain destroys the domain's own budget, which deletes every object charged to it, each child budget of its outer budget, one per connection or shared area, once both parties have let go, and the outer budget once no child remains and the crash area is read; the reaper frees what they held ([Budgets](#budgets)) | the domain's exit, with its status, in the system domain ([design-system.md](design-system.md#ending-a-domain)) |
| The root task faults, halts outside an ordered shutdown, or stops petting the watchdog | the fault classifier; the first space's stop; the watchdog's timer | the machine, after the crash record is written | none: the machine ends as `erx.panic` says, and the next boot hands the record to the new root task | the crash record on the console, and in the inspector after the reboot ([The root task](#the-root-task)) |
| A sub-space faults or ends | the fault classifier; `erx_space_stop` | as for a domain, below its creator | its creator | whatever its creator reports |
| A device floods interrupts | every fire of a level-sensitive line, and every fire of an edge line or MSI that cannot be delivered at once, masks the line until its delivery is taken or acknowledged ([IRQ objects](#irq-objects)) | none | none needed | the driver's own slowness |
| A device faults in DMA | the IOMMU's fault queue | the faulting access aborted; a window past `ERX_DMA_FAULTS` records in a period quarantined; the queue's interrupt masked for the rest of a period once `ERX_IOMMU_FAULTS` records are drained | the device service resets the device and, for a quarantined window, destroys it | a counted fault on the window, fired at its IRQ object; the quarantine in its inspection; overflow episodes counted, lost-record count unknown |
| An IOMMU misses the deadline of its synchronisation | the driver's poll, `ERX_IOMMU_SYNC_NS` | the IOMMU failed: no new window or mapping on it, and the pages whose invalidation it owed kept from reuse, still charged | none; the devices behind it are lost until the next boot | a log line naming the IOMMU; `ERX_EDEAD` from calls on its windows |
| A doorbell or a gate is deleted while someone waits on it | the release | the waiter woken once, or its blocked send failed with `ERX_ESTALE` | none needed | the waiter finds out at once |
| An asynchronous error presumed to be a thread's | the exit window or user mode | the thread stopped | as for a fault | a fault record of kind `async_error`, which the inspector shows as a presumption |
| An asynchronous error a posted write reports after its window | the next window, or user mode | the thread there stopped, or a log line, unless the platform's error records name the source | as for a fault | the same record, on a thread that may not be the one whose access caused it |
| An asynchronous error the platform's error records attribute to a device | `erx_async_error_classify`, from the records | the device's window quarantined | the device service resets the device or its PCIe segment | a log line naming the source; the quarantine in the window's inspection |
| A corrected or latent asynchronous error | `erx_async_error_classify` | nothing | none needed | a log line |
| An uncontainable asynchronous error | the asynchronous error's handler, from what the architecture reports | the machine | none | a panic report |
| A kernel invariant violated | assertions, the exception entries | the machine | none | a panic report on the console with the cause, the program counter and the fault address; the registers, the backtrace and every CPU's state only in the crash record's full form, which a development build keeps |
| A device-tree or boot-image error | the validators | no boot | none | the failing check and offset on the console |

**Inspection.** `erx_object_info` answers topics for every object (its type,
object id, name, budget, references, and per-type details: a space's
mappings and reserve, a thread's state, wait and registers when stopped, a
group's grant and usage, a gate's binding and blocked senders, an IRQ
object's state and binding, a space's children), with
`INSPECT` for anything beyond the basic topic. The basic topic is the
object's type and the capability's rights only; an object id needs
`INSPECT`, and being a keyed permutation of a counter, it reveals nothing
about objects others create. The inspector presents them as kernel-reported
records ([design-live.md](design-live.md#inspection)). The trace ring and
the kernel log complete the picture; the panic report is the last resort.

## Security

**Trust boundaries.** The kernel trusts nothing in user mode. Every register,
address, length and capability a thread passes is decoded once by generated
code and validated; no argument is a pointer the kernel follows, and
every field of the UTCB or of a shared area is loaded once and validated
([Arguments and results](#arguments-and-results)). The system domain, the root
task, is trusted with the authority it receives at boot; every other
domain with nothing beyond what it was given, and a sub-space with what
its creator gave it. Code of unknown provenance runs
only in an address space of its own, a domain or a sub-space that a domain
created, holding only the capabilities it was handed.

**Threat model.**

| Adversary | Can | Cannot |
| --- | --- | --- |
| Code in an untrusted domain or sub-space | anything inside its space; any call its capabilities allow; exhaust its own budget and grant; pass what it holds, within the pass sets, to a space it shares a gate with, and map what it is passed while the giver's budget lives, and fault on it afterwards; trigger the IRQ objects it holds a capability to | read or write another space's memory; name an object it holds no capability for; gain a right; put a capability into a table that did not reserve a slot for it, or that it did not create; pass code, device or structural authority; spend another budget or grant; outlive the space that created it; divert its faults from its fault gate; block the kernel; panic it |
| A domain holding `SPACES` | create sub-spaces within its budget: their records, translation tables and ASIDs; create threads in them, map into them and give them capabilities, budgets carved from its own and groups created below the group it was given for them; stop them and the spaces below them; create them faster than ASIDs can be recycled | give a sub-space more than it holds, or `CODE`, or a JIT space unless its own space is one; reach a space it did not create, or let one outlive it; spend beyond its budget or its group's grant, change that grant, or make another domain's calls pay for its sub-spaces |
| A device behind an IOMMU, or its driver | fault on every access through its window; present the requester id of another function of its isolation group, which reaches the same window; use an address its driver unmapped, reaching whatever its own window maps there then; raise any line of an MSI frame that does not identify its writer | reach memory without a window, or a page the kernel freed (K9); present a requester id outside its isolation group, since only a function on a fixed bus has a stream, and the fabric sets the ids there ([Resources, DMA windows and consoles](#resources-dma-windows-and-consoles)); keep a request queued in the device across a change of driver, since the device service resets the function before its next window; make the kernel drain more than `ERX_IOMMU_FAULTS` fault records in a period, or go on faulting past `ERX_DMA_FAULTS` records in one, after which its window is quarantined ([DMA and the IOMMU](#dma-and-the-iommu)) |
| A driver domain holding a confined device, or a shim in its sub-space | drive its device; DMA into memory objects mapped in its window | reach memory outside its space and its window |
| A driver domain holding an unconfined device | everything its device's DMA can reach | nothing is enforced: it is part of the trusted base, and a release configuration gives such a device a domain of its own and creates contiguous memory only when the boot image allows it |
| A device writing shared memory | write the rings and buffers it was given; raise any line of an MSI frame | make the kernel trust what it wrote: the kernel reads no ring a device writes, and the IOMMU's fault queue, which the IOMMU writes, is decoded with bounds checks |
| The PCIe enumerator, or a device answering it | read and write every PCIe function's configuration space; enable memory decoding and bus mastering; answer configuration reads as a device likes | give a confined function's DMA any reach, since the IOMMU aborts every stream not bound to a window; reach a BAR or an MSI the device service did not create for a driver; touch the kernel's state: configuration space is read in user mode, by a bounded parser with a fuzz target ([design-system.md](design-system.md#devices)) |
| The root task | everything, by design: it holds the root authority | keep the machine up without petting the watchdog, or survive its own fault or halt: each ends the machine after a crash record ([The root task](#the-root-task)) |

**Hardware configuration.** The kernel-mode control registers are written
from zero plus the enables the binding lists
([design-arch-aarch64.md](design-arch-aarch64.md#hardware-configuration)):
translation and caches; stack-alignment checking, and no alignment
checking of other accesses, which runtimes rely on; writable
mappings execute-never; user-mode cache
maintenance by address and the cache geometry,
which a JIT needs; pointer signing with per-space keys and
branch-target protection where the CPU has them; and exception entry and
exit that synchronise the CPU's context. FP and SIMD are enabled for user
mode and vector extensions stay trapped; user-mode debug and performance
counters are disabled, and user mode may read only the counter the time
page needs. Every other feature with user-mode state that the CPU's
feature registers report is left disabled, and the boot audit lists them
(K15).

**Resource limits.** Every object is charged to a budget; a space's capability
table, mappings and threads have limits chosen at its creation; every call
is bounded (K13); a group's executors are at most 64 and its depth eight;
a tree of spaces is at most 64 deep and a tree of budgets
`ERX_BUDGET_DEPTH_MAX`; what waits at a fault gate is bounded
by the threads and spaces it serves, one record each.

**What a budget's holder can cost others.** A holder spends up to its cap
and no more: within its guarantee it takes from no one, and beyond it
only the room of its ancestors, which is memory promised to nobody; the
guarantees of its siblings, of its parent and of every budget off its
chain are untouched (K32). What a borrower can make a sibling lose is
therefore the sibling's borrowing beyond its own guarantee, which the
carver bounds by the caps and guarantees it sets. A wall, which every
domain's budget is, is admitted or refused at itself, and it borrows
only what its own carver's shrink left above its guarantee, which no
charge can grow. Elastic budgets under one wall share it on purpose:
each program of a session sees, in what its own `mmap` is admitted or
refused, how much its siblings have borrowed from the pool; that is a
channel between the programs of one pool, and within a pool it is the
intent, since the pool is one session's memory. Programs that must not
share that channel belong to different pools or different sessions,
which are different walls, and a domain shares it with nobody, since
nothing of another domain's is counted against its cap. A charge that
borrows holds at most `ERX_BUDGET_DEPTH_MAX` locks for bounded work and
waits for nothing: a charge ends when memory is released, so no charge
runs or waits for anyone's freeing, and whether a charge is admitted
says nothing about when anyone freed anything. What the budgets do not
wall off is the physical free pool, which is one for the machine: the
backing of an admitted charge takes released pages off the list itself
when none is free, whoever released them, and waits out their grace
period, fewer than two periods per part of 64 pages, so a charge of `n`
pages costs its caller at most that per 64 pages of it and never more,
since a backing never loses a page it took and the list's and the
allocator's locks serve takers in order, each behind at most `ncpus -
1` holders of bounded critical sections ([The reaper](#the-reaper)).
The reaper's lists are per CPU and served in order, 64 items per reap
deadline on a CPU that never idles, so a domain that destroys `m`
objects on one CPU delays by at most `1 + floor(m / 64)` deadlines the
puts and record frees that other parties' calls queue on that CPU after
them, and with them the return of those parties' cache pages; `m` is
bounded by the records its budgets hold, and the delay touches cache
pages alone, never data pages, whose release refunds at once ([The
reaper](#the-reaper)). The released list holds at most the
machine's pages: a domain that releases and charges without pause moves
at most the machine's free pages onto the list, then cycles its own,
paying a range call, a backing wait and a fault per page, on its own
CPU time; while it does, the free pool is empty and every other
domain's backings pay that per-part cost. The time a backing takes
tells its caller whether the machine had a free page and how long the
current grace period lasts, which is the longest part any CPU is in: a
channel from every domain's releases and kernel activity to every
domain, which the one page allocator's lock opens as well, and which is
accepted, as the shared pool's refusals are within a pool. A faulting
thread learns nothing of the kind: a fault takes from its own reserve's
pool and never waits. One more thing a party can keep from a budget is
a kernel record's cache page: a thread that holds an object counted
across a preemption point, as a memory window's caller does between the
parts of `erx_mem_copy`, keeps that record's slot, and so its cache
page, charged to the record's budget, or to that budget's nearest live
ancestor after a destroy, until its call next runs, and a call that is
not scheduled holds it indefinitely. It can do so directly only for an
object it holds a capability to, which the budget's owner or its carver
gave it; a space reaches further, as below.
What one such object keeps is its record's cache page, two pages for a
thread on the stopgap, whose record is its block, one more for a space,
its root table, kept until its last reference has gone, and, since a dead
budget's tombstone waits for the last record charged to it, one cache
page for the tombstone of each dead budget between the object's budget
and its nearest live ancestor, fewer than `ERX_BUDGET_DEPTH_MAX`; so
what a party can withhold is at most `ERX_BUDGET_DEPTH_MAX` cache pages,
one more for a space and one more for a thread on the stopgap, for each
object it was given. A space's record also keeps the record of each
released space above it, at most `ERX_SPACE_DEPTH_MAX` of them, each with
the same cache pages at its own budget, which may be a budget the holder
was never given: one space held counted withholds at most
`ERX_SPACE_DEPTH_MAX` times `ERX_BUDGET_DEPTH_MAX` cache pages, from
whoever paid for those spaces, and on the stopgap one root directory for
each of those spaces as well. A destroy under way holds the same chain:
a space that destroys its own child C, below a parent P on another party's
budget, and leaves that call unscheduled once its walk has unlinked C keeps the
spaces below C undeleted, their capabilities answering, and through them
the records of C and P and the budget's tombstone, for as long as that
group goes unscheduled, one chain for each call so stalled. All of it
is counted at the
nearest live ancestor, as a connection's survivor keeps the connection's
child budget alive and nothing else
([Budgets](#budgets)). A budget has one watch and an IRQ object is the watch
of one budget, costing one compare per adjustment and one trigger per
crossing; a resize is one chain.
Resizing is by `DESTROY`, which only carving places in a slot and which
reaches a holder only by the carver's pass; a shrink below the spending
stops the holder's charges, which the carver could already stop by
destroying it, so resizing adds no authority to what the carver held.

**What a stop can cost.** A holder of `STOP` on a space, or of `DESTROY`
on a group or a thread, starts finishing work that no grant caps, its
own included: the killed threads finish at the finishing level, outside
every quota (K18). That work is bounded twice. Per CPU, by the finishing
share: the level runs for at most `ERX_FINISHING_TICKS` of every
`ERX_FINISHING_PERIOD` ticks of that CPU, 4 of 8, whatever is killed
there and however many parties kill, so a CPU's user threads keep at
least the rest of every period and wait for the level at most two shares
at a stretch, where two periods meet
([design-scheduler.md](design-scheduler.md#pick-and-dispatch)). In all,
by what the stopped space's budgets paid for: a finishing thread runs
only the parts its call has left, each bounded (K13) and their number by
the records the call walks, which the stopped space's budgets, or for a
teardown the budgets of the spaces whose slots and mappings name the
object, paid for; and a stopped space creates no thread and starts no
call, so the work is fixed at the stop. A killer can therefore make a
CPU's user threads lose at most the share, makes them lose nothing on a
CPU where none of its target's threads is, and gains nothing from its
own grant, which nothing of the finishing reads: the accounting adds
the time to the `finishing_ns` of the target's own groups, apart from
their usage, and no grant, zero included, changes what runs. A deletion's
walk runs on its caller's time, and the spaces below a deleted one may be
charged to other budgets and hold many mappings, so a party that hangs a
tree under a space on another party's budget makes that budget's destroyer
spend the time to tear it down, bounded by the records the party paid for. What it can do is spend the share of
every CPU its target's threads are on for as long as their remaining
parts last, which is what its target's budgets bought.

**Escaping.** Text from user mode reaches the kernel log only through
`erx_log_escape`, and the panic report escapes everything it did not
write.

**Information leaks.** A status code reveals only what the caller's capabilities
already allow: an unknown capability and a stale one both return
`ERX_ESTALE`, and inspection needs `INSPECT`. Freed pages are zeroed before
reuse. The kernel maps no secret of its own into user mode. The one
secret it derives, the device secret, reaches the root task alone, on a
page whose rights keep it in the root task's table ([Rights](#rights)).
The root-task entry derives the sealing secret from it into the sealing
page and closes the device-secret page before ERTS starts, keeping the
sealing page unmapped in the system domain, and only the vault's domain
maps the sealing page ([design-system.md](design-system.md#the-vault));
the vault's runtime is inside the speculative residual
([design.md](design.md#residual-risks)). The crash record's brief form,
a release build's, carries no secret: the cause, the program counter and
the fault address, and no register, stack or text. The full form, a
development build's, carries the registers and the log's tail and so may
carry what the root task held, a passphrase it was checking among it,
and the system domain shows it to holders of the system-shell facet
alone ([The root task](#the-root-task)). Timing channels between domains
sharing a CPU are a residual risk too.

**Speculation.** The kernel applies the mitigations Linux applies on each
architecture, each chosen from the CPU's identification registers and
from what the firmware reports, against branch-target injection,
branch-history injection, speculative store bypass and rogue data-cache
loads; the binding lists them with their sources and the boards' needs
([design-arch-aarch64.md](design-arch-aarch64.md#speculation-mitigations)).
Whether the kernel is unmapped from user tables on affected cores is each
board port's decision ([plan.md](plan.md#beyond-the-plan)). Every
firmware call goes through one routine. Each mitigation's cost on entry is
measured on each board with `tools/erx bench nullcall`.

**Residual risks accepted.** Unconfined DMA where no IOMMU confines a
device, as for QEMU `virt`'s virtio-mmio devices and the Raspberry Pi
boards' DMA devices ([design-platforms.md](design-platforms.md#dma)); the
boards' closed boot firmware and the firmware that stays resident in a mode
more privileged than the kernel's
([design-platforms.md](design-platforms.md#firmware)); an asynchronous error
that a posted write reports after its own window, which the kernel can
only presume to be the next thread's where the platform has no error
record naming its source, and one the architecture reports as
uncontainable, which panics; speculative and cache side channels between
domains sharing a CPU, and across CPUs through shared read-only pages, since
user mode may clean caches by address; a fault of the root task, which
ends the machine; a passed object, which its giver's budget pays for until
the giver deletes it or its budget is destroyed; speculative reads from user mode that the kernel's
mitigations do not cover; MSIs through an MSI frame, which does not identify
the writer, so a device can raise any line of the frame, a spurious
interrupt to another driver that validates its rings anyway and that an
interrupt controller with per-device MSI translation closes on boards that
have one; ASID rollovers that a domain forces by creating and running
sub-spaces quickly, each costing every CPU one invalidation of its whole
TLB, at most about once a second for each CPU that creates spaces on the
first architecture, whose 65,535 ASIDs
([design-arch-aarch64.md](design-arch-aarch64.md#tlb-maintenance)) must
all be used between rollovers, while creating and running a space takes
an estimated 15 microseconds or more; the stopgap's unhardened
state, accepted because only trusted code runs on it.

## Verification and testing

[Protocol verification](design-verification.md) defines independent
TLA+/TLC models, their mapping to C core decisions and concrete tests, and
the bounds and hardware assumptions every result states. The focused
CBMC evaluation of actual budget and capability code is scheduled with
the kernel pilot in [plan.md](plan.md#verification-work); it supplements
the host exploration and conformance requirements below.

| Layer | What | Where |
| --- | --- | --- |
| Pure core | the capability table, the slot's sequence lock under TSan with slots churned by closes, moves and deletions on other threads, the trace ring under TSan with records overwritten while other threads read them, the deletion core, the grace-period tracker with its retire, over an item retired while no period is in progress and one retired after a CPU's report for the period in progress, the release core with a backing whose owner, or an enclosing lock its thread holds, is closed at every part boundary, and a construction whose budget is destroyed at every step and between every insert of its publication, which must leave the object wholly attached and then wholly detached, or never attached, with a seeded publication that inserts without the object's existence lock, which the model catches as a child attached to its parent after the parent's budget tore it down, and a seeded backing that reads only its owner's lock, which the model catches as a child backed to its full size after its copy's target was destroyed, the ticket lock under TSan with every thread contending without pause, budget arithmetic with pins passing through live and dead budgets, with the inspector's figure for a destroy compared against what each destroy gives back, after pins at every depth, and a seeded pin that marks a tombstone's cache page at the close instead, which the comparison catches at the first destroy after a pin, mapping plans and the edge rule, the thread and IPC state machines with the pass plan, the IRQ object machine, the vCPU step, the stop and deletion walks, the kills over a stopper deleted, descheduled behind a spinner and killed in turn, a killed thread whose own path is at zero grant and a second stop of the stopped space, with a seeded kill that throttles the thread on its own zero-grant path, which the model catches as a finishing thread that never dies, and a seeded charge of the finishing time to the stopper's path, which the model's `finishing_ns` counters catch, the stopper's wait, the wait for children's records and the holds, with two holds on one space and a resume of either while a quiesce and a copy run under the other, fault classification and the fault decision over every mapping kind, page state and access, store tracking over stores, faults, removals of translations and reports interleaved on several CPUs, among them the trace of a report, a store to a reported page and the next report, which must report it again, and the trace of a store, the removal of its translation by an unmap, an `exec`'s replacement of the space or the space's destroy, and a report, which must report the page, under both the hardware's dirty bit and protection faults, the window functions over deletions, seals and copy-on-write between every two parts, `erx_uword_load`'s walk over every descriptor kind and unmapped level and over outputs in every range the direct map leaves out (the boot image, device registers, a board's crash region, the kernel's text), each refused with `ERX_EFAULT`, budget destruction over trees of budgets and objects charged across them, the boot-image and manifest validators, the device-tree and command-line parsers, the carve of requester ids, which gives a stream only on a fixed bus, the watchdog machine over pets, ticks, arming and the mode, the crash record's check, the scheduler's core: unit and property tests, with protocol machines explored exhaustively | host, under ASan, UBSan and, for concurrent code, TSan |
| Fuzzing | the device tree, the kernel command line, the boot image's index, locator and file check, and manifests, system-call argument decoding, message tags, typed items and buffer descriptors, resumed vCPU frames, the previous crash record in both forms, checked by a build of each form | host, `make check-fuzz` |
| Conformance | every kernel call's contract, from test domains: arguments at and beyond their limits, every error, every right missing, every outcome; run identically on erXos's kernel and the stopgap, among them a stop of a space whose thread waits on an IRQ object while the IRQ fires, and of one whose thread is inside a vCPU resume, each posting its exit record only after the thread has died and running none of its user code after it, and a memory-object map and the range calls racing the destroy of their space, which add no record to it (K26's container test); a store to a shared object's page followed by an unmap of the mapping, or by a stop and destroy of the storing space, and then `erx_mem_dirty`, which reports the page stored; umtx waits on a word of a boot-image slice and of a device's register window, each refused with `ERX_EFAULT` before any load; `erx_mem_copy` from a child of a sealed paged object, which returns the parent's bytes for every page the child does not own and the child's for the pages it owns, against the same copy with the child's pages seeded with a marker; a thread parked inside `erx_mem_copy` between two parts while the source's budget is destroyed, whose next part fails with `ERX_ESTALE`, after which the reaper frees the budget's tombstone last and the parent's free capacity is whole again, under ASan on the hosted kernel; a stop of a three-level tree from a thread whose group's grant is set to zero right after the word is stopped, then between two parts of kills, then between two levels of the walk, each followed by a stop of the same tree, and of its parent, from a thread with quota, whose own walk posts the missing kills and after which the record comes, with a seeded second stop that only waits never receiving it and failing the case's deadline; a killed thread holding a space's lock across a long range call while a waiter on another CPU and one on its own CPU take that lock, and the same holder killed while a waiter runs it by helping, in which the holder's time after the help's current part lands in its own path's `finishing_ns`, the waiters' paths gain only their own waiting, and the holder's finishing stays within its CPU's share, with a seeded help of a dying holder moving its time to the waiter's group, which the counters catch; a fork given up by resuming the copy's hold while the job's hold remains, which leaves the parent held and the copier reporting `ERX_EBUSY`, and the same fork given up while the copier is between two parts of a child's backing, which leaves nothing charged to the child's budget once the child is destroyed | QEMU, TCG and HVF |
| Hostile domains | random calls, closed and foreign capabilities, rights probing, passes of stale, duplicated, unpassable and surplus capabilities, of two copies of one object, and receivers that end mid-pass, writes racing a seal, stores racing a store report, windows whose objects are deleted mid-copy, umtx waits on words unmapped, remapped and freed by other threads during the wait, budgets destroyed while other spaces map their objects, deletions racing lookups, copies, moves and mappings, accesses to deleted memory, mapping probes, threads that fault in every exception class, executors calling every blocking call, groups that spin, servers that never reply or drop their callers, doorbells and gates deleted under their waiters, UTCBs, vCPU frames and windows rewritten while the kernel reads them, calls that pass kernel addresses wherever an argument is an integer, sub-spaces created to the depth limit and churned, devices that flood interrupts and devices that fault through the IOMMU without pause | QEMU |
| Isolation | freed pages handed between domains on four CPUs; TLB maintenance under concurrency; one domain reading another's memory through every path; a sub-space reaching beyond what its creator gave it | QEMU |
| Timing | every call at its limits, with every stretch with interrupts masked checked against the 20 us bound under HVF | QEMU, HVF |
| Determinism | `erx.det=1` boots twice, compared byte for byte; a run that takes input after it starts, recorded and replayed by the harness with QEMU's record and replay and compared by its structured event trace | QEMU, TCG |
| Build checks | the chokepoint checks and the stack proof below, each with a test that seeds a violation | every build |

### Chokepoint checks

Every rule of the form "only X does Y" in this document is a check that
runs on every build, and each check has a test that feeds it a fixture with
one violation and requires it to fail. The checks read symbol references
and relocations in the kernel's objects and the linked image (`llvm-nm`,
`llvm-readelf`), its disassembly (`llvm-objdump`), and the syntax trees of
its C sources (clang's JSON syntax-tree dump).

The rules are declared as data in one registry, one file per group
under `tools/lib/erx/chokepoint_rules/` loaded in sorted order, with
what they share in `tools/lib/erx/chokepoint_rules.rb`, and `make check`
evaluates them over every file git lists. Each core has a group named
after its source, stating its rules or why it has none, and a core with
no group stops the load, so a rule cannot vanish with its file. A rule
names the files it reads, what it forbids
there and the sites allowed to do it, and carries the seeded violation its
host test requires it to catch; text rules read each source after line
splicing and comment removal, with every include directive limited to a
plain header path so that no computed include or included non-header
carries text past them. A rule another check enforces names that check
and its test. A rule read from the cores' call graph, such as the one
function that clears a capability slot, is declared in the same
registry and evaluated by the stack proof on the graph of every
optimisation level it proves, before it proves it. A rule whose sites
are not yet in the tree is declared
pending with the files that would be its first sites, and the check fails
when one of them appears, so no code lands before the check that polices
it.

A check proves the shape of the code: which code can reach an operation,
where a type is built, that a path is bounded. It does not prove that the
code allowed to perform an operation performs it only when it should:
that a call's decision is right is held by the state machine that makes
it, explored exhaustively on the host, and by the conformance and hostile
suites, which drive the real kernel ([Verification and
testing](#verification-and-testing)). And a plan validated whole is bound
to what it validated: it is applied under the locks it was validated
under, as a pass is, against reservations it took first, as a commit is,
or after checking a generation that every change of the state it read
advances, so nothing it checked changes unseen before it is applied.

| Rule | What the check requires | Evidence |
| --- | --- | --- |
| only the capability table's code reads a slot (K1) | the ABI file marks the slot's layout private to `kernel/core/cap.c`, so its record, offsets and accessors are generated only into `kernel/generated/cap_slot_impl.h` and `erx_cap_slot_t` is an incomplete type everywhere else; the chokepoint rule generated from that declaration lets only its owner and the owner's host tests include that header, and no other file define the record | the compiler, which refuses a member, offset or accessor of an incomplete type, and the generated text check of includes and definitions, with a seed built from the layout; a tag a macro pastes together passes the text check until the syntax-tree leg reads definitions ([TODO.md](../TODO.md)) |
| only the mapping core writes a mapping record, and only from a plan it made (K4, K5) | `map-records-private`: `struct erx_mapping` is defined only in `kernel/core/map.c`; `map-core-opaque`: a plan's, a tree's and a detached subtree's core part are `core_opaque` bytes whose layout only that file knows, and no other file names them, which holds against naming and not against a deliberate cast |
| only the capability core writes a table (K1, B4) | the table's record is defined only in `kernel/core/cap_impl.h` and `erx_cap_table_t` is an incomplete type everywhere else; its directory and pages reach the core as untyped storage it owns from then on; only `kernel/core/cap.c` and its host tests include that header, and no other file defines the record | the compiler, which refuses a member of an incomplete type, and the `cap-table-private` text check of includes and definitions, with a seeded member write; a tag a macro pastes together passes the text check until the syntax-tree leg reads definitions ([TODO.md](../TODO.md)) |
| rights only shrink (K2) | an `erx_rights_t` constructed, or its `bits` written, only in `kernel/core/cap.c` | syntax trees |
| only `erx_budget_adjust` changes a budget's counters (K3, K32) | the `guarantee`, `cap`, `used`, `carved`, `lent`, `pinned`, `dead` and `threshold` members of `erx_budget_t` written only in `kernel/core/budget.c`, by `erx_budget_adjust` and the resize, close and watch it serves | syntax trees, with a seeded write of `used` from a charging call |
| only creation calls, `erx_cap_dup`, the pass and `erx_space_copy` install capabilities (K17) | the table's fill referenced only from the generated dispatch's installation step, which the generator emits for the creation calls alone, from `erx_cap_dup`, `erx_pass_install` and `erx_space_copy`, and `erx_pass_install` only from the IPC calls and `erx_cap_pass` | relocations |
| only one function clears a capability slot (K21, K25) | `erx_cap_slot_clear`, which decrements the object's capability count and reports its release, or hands the count to a pass, referenced only from `erx_cap_close`, `erx_pass_take`, `erx_space_clear_caps` and the deletion walk | relocations |
| objects hold no counted reference to each other: every pointer from one object's record to another's is an attachment field of the target, named `att_` or `in_`, and only threads count references | every member of an object record that points to another object record is an `att_` list or `in_` link, or is listed with the attachment that protects it, such as a space's parent pointer, which its parent's count of holds protects, a count of records and not a reference; `erx_object_ref` referenced only from the dispatch, the wait paths and the handlers that pass a preemption point | syntax trees, with a seeded object pointer outside an attachment |
| only the insert functions of `kernel/core/attach.c` link anything onto an object, each after checking its state, every type's teardown walks every attachment field of its record, only `erx_object_lock_cap` and `erx_object_lock` take an object's capability lock, and only `erx_object_lock_existence` and `erx_object_lock_existence2`, which take counted references first, take its existence lock (K21, K26) | every member of an object record whose name begins with `att_` written by an insert only in `kernel/core/attach.c`, every exported function there calling `erx_object_state` before its insert, and every such member referenced by its type's teardown; the helping-lock acquire on an object's `lock` referenced only from the two capability-lock functions, and on its `existence` only from `erx_object_lock_existence`, `erx_object_lock_existence2`, `erx_object_lock_counted_existence` and `erx_object_lock_fresh_existence`, the first two after their calls of `erx_object_ref`, the third on an object its caller holds counted and the fourth on a record only its caller can reach, whose try of the lock must succeed | syntax trees, with a seeded fresh take of a published object's lock, which the debug assertion catches |
| no object pointer from a lookup is used after a preemption point (K1) | in debug and host builds, `erx_uref_get` and `erx_object_ref` compare the reference's epoch with the thread's count of preemption points, which every explicit point and every helping-lock acquire advances, and stop the build's tests on a mismatch; `erx_uref_t`'s members read only in `kernel/core/cap.c`; the generated decoder looks up every plain capability argument after every other argument and existence lock of the call | syntax trees; the generator's test, which feeds it a call declared with a capability first; the hostile and fuzz suites in debug builds |
| an object's state only advances, from live to released or deleted and from released to deleted, one destroy alone tears an object down, and only the reaper frees an object, after its grace period (K21, K26) | an object's `state` word written only by `erx_cap_slot_clear` in `kernel/core/cap.c`, which writes `ERX_OBJ_RELEASED` and only over `ERX_OBJ_LIVE`; the invalidation of an existence lock, one atomic operation whose result decides which destroy goes on, and for a space goes on to its walks, the walk that unlinks it running its teardown whatever that result was, referenced only from the deletion core in `kernel/core/delete.c`; the object free entry point referenced only from the reaper's put and free steps in `kernel/core/reaper.c` | syntax trees, relocations |
| a sealed object is never written (K23) | a memory object's writer count changed only by `erx_mem_writer_enter` and `erx_mem_writer_leave`, which the writable-mapping insert, `erx_dma_map`, `erx_window_write` and `erx_mem_supply` call around every write path, and read by `erx_mem_seal`; the copy into an object's pages referenced only from those paths | syntax trees, relocations |
| only the crash core builds a crash record (K31) | `erx_crash_record_write` and `ERX_CRASH_MAGIC` named only in `kernel/core/crash.c`, its seam, the binding's end funnel and the core's tests, by the `crash-record-writer` rule | a test seeds a second writer in a core and in the glue |
| only the root task pets the watchdog, and every end of the machine passes one funnel (K19, K31) | `erx_watchdog_pet`'s handler requires `POWER` on the root resource, which no carved resource carries, by its generated decoder; the watchdog's deadline written only in the watchdog core, `kernel/core/watchdog.c`; the firmware's end calls referenced only from `erx_machine_end_effect`, which `erx_panic`, `erx_machine_end`, the lease's deadline and the watchdog's reach, and the crash record's writer referenced only from `erx_panic` | relocations, syntax trees |
| every return to user mode passes the one decision of deaths, stops, holds and upcalls (K18, K29, K30) | the exit path, which alone holds exception-return instructions besides the boot entry's drop, calls `erx_return_check` before it restores the user registers; a space's hold count and its `quiesced` mark are read only there and in the space core's pause, resume, quiesce and copy functions, and changed only by them: the `holds` word, the pause count and the slots' tickets in `erx_space_pause` and `erx_space_resume`, `quiesced` set where the active count falls to zero under a hold, in the call boundary's decrement and in `erx_space_pause`, and cleared in `erx_space_resume`; `att_quiescers` woken only by the space core's one quiesce completion, called where the mark is set, in `erx_space_resume` for every quiescer waiting under the ticket it resumes, whatever other holds remain, in `erx_space_stop` and in the space's teardown | disassembly, syntax trees |
| only `erx_vcpu_control` arms a thread for upcalls (K20) | the thread's armed flag written only in `erx_vcpu_control`, which checks the class, and in the thread's teardown | syntax trees |
| kernel memory is allocated only through the budget-charging funnel (K3) | the page allocator's take and put referenced only from the backing of `erx_reserve_charge` and the free step, in `kernel/core/page.c`, and the boot allocator only from boot code | relocations |
| a page enters a reserve only by the backing of a charge, comes into use only through `erx_reserve_take`, is released only through `erx_page_release`, which retires it and appends it to the released list before it refunds its charge, and leaves the list only through `erx_released_take`, after its grace period unless a backing takes it and waits that period itself; an admission not backed is cancelled only by its own backing, and every stamp comes from the tracker's retire (K6, K9, K32) | a reserve's `charged` and `backed` and its pool's insert written only in `erx_reserve_charge`, `erx_reserve_cancel`, `erx_page_release` and the backing's install in `kernel/core/page.c`, `erx_reserve_cancel` referenced only from the backing, the pool's remove only in `erx_reserve_take`, the released list's append only in `erx_page_release`, a page's refund only there, the list's unlink only in `erx_released_take`, which the free step in `kernel/core/reaper.c` and the backing alone call, and the tracker's current and completed counts written only in `kernel/core/grace.c` and read for a stamp only by `erx_grace_retire`, with a seeded release that refunds first, a seeded fault that takes a page from the allocator, a seeded backing that releases its own hand and a seeded append that stamps the current count | relocations, syntax trees |
| only `erx_pte_make` builds a user translation entry, and only `erx_cow_install` makes a child's page its own (K22) | the entry encoder and the child's page-tree insert referenced only from those functions | relocations |
| the kernel never accesses memory through a user address (K7) | the architecture's unprivileged access forms appear nowhere in the kernel image; an integer becomes a pointer only in the converters of [Typed values](#typed-values) and the generated accessors; `erx_uword_t` read only by `erx_uword_load`, which reads descriptors and the word only through the direct map, and loads the word only after checking its page against the direct map's ranges | disassembly, syntax trees, with a seeded walk that skips the check |
| no store is lost when a translation goes | the freeing of a plan's cleared entries and detached tables referenced only from the plan's last step, which calls `erx_vm_fold` on every cleared entry of a shared object's page before it frees anything | relocations, syntax trees |
| memory user mode can write is reached only through its accessors (K7) | loads and stores of the kernel-user page, UTCB, vCPU state and shared-area types only in `erx_shared_load_*`, `erx_shared_store_*` and `erx_msg_copy`, and of a memory object's pages on a caller's behalf only in `erx_window_read`, `erx_window_write` and `erx_mem_supply`'s copy | syntax trees |
| a sequence-counted record's fields are reached only through their generated accessors ([Sequence-counted records](#sequence-counted-records)) | the members of every record type the ABI file declares sequence-counted, the capability slot and the trace record among them, accessed only in the generated load and store functions, which use the rule's orders | syntax trees |
| only the switch routine changes the running thread | the switch referenced only from the scheduler's effect layer in `kernel/sched/switch.c` | relocations |
| a group's grant, the group a thread is charged to and the links of the ready queues are written only in the scheduler core (S5, S6) | the core's records defined only in `kernel/sched/sched_impl.h`, which only `kernel/sched/sched.c` and its host tests include, and every other file names a record's tag only to refer to it | source text |
| a thread's stored urgency is only ever its own resolve (S5) | the core's one form of store, `thread->urgency = erx_sched_resolve(thread).raw;`, in `kernel/sched/sched.c`, and no other write, increment or address of the field | source text |
| interrupt handlers make no indirect call | the call graph from the interrupt and asynchronous-error entries has no indirect branch | disassembly |
| interrupt handlers never nest, which the stack proof assumes | the call graph from the interrupt and asynchronous-error entries reaches no preemption point and no accessor that unmasks interrupts | disassembly |
| no FP or SIMD in the kernel (K10) | no FP or SIMD encoding outside the two FP save and restore routines | disassembly |
| system registers and inline assembly only in their accessors | system-register instructions only in generated accessors, the named barrier and maintenance helpers and the listed assembly files; the `asm` keyword only in generated headers and those helpers | disassembly by symbol, syntax trees |
| TLB and cache maintenance only in the maintenance helpers | TLB and cache maintenance instructions only in the architecture layer's maintenance helpers | disassembly |
| exception returns and firmware calls only where listed | exception-return instructions only in the exit path, which an upcall also leaves through after rewriting the saved state, and in the boot entry's drop from a more privileged mode; firmware-call instructions only in the one firmware-call routine, which serves the CPU and power calls and the speculation workarounds; a firmware mailbox's registers referenced only from the platform's trial request and its boot-time key read | disassembly, relocations |
| a board's key is read once, at boot | the key read and the derivation sit in the boot-only section, which nothing references but boot step 6 and which the kernel unmaps before it starts the root task | relocations of the linked image, with a seeded reference from outside boot |
| the kernel touches no PCIe configuration space | no register accessor of a PCIe bridge is linked into the kernel: the platform's register sources mark bridges as the PCIe enumerator's, and the generator emits no kernel accessor for them | relocations, the generator |
| device registers only through generated accessors | the `volatile` qualifier only in generated headers | syntax trees |
| only the early-console writer writes a UART's registers in the kernel | each UART's register accessors referenced only from the early-console writer in `kernel/platform/`, which the boot path, `erx_panic` and `erx_machine_end_effect` alone call | relocations |
| untrusted text reaches the log and the panic report only escaped | every call of the log's formatting function goes through `ERX_LOG_FORMAT`, which joins `""` to its format so that only a string literal compiles, the function escapes every argument and its own text, and its raw append, ring and text store are named only in `kernel/core/log.c` and its header | the compiler, the source text |
| the hosted backend's log reaches its console only through one sink | only `liberx/backend/hosted/log.c` of the hosted backend names a write or a standard stream, and it is given only rendered lines | the source text |
| data holds no code pointer outside an allowlist | every absolute relocation in a data section of the image that targets text belongs to an allowlisted table: the generated handler table | relocations of the linked image |
| only `liberx`'s `fiasco` backend issues Fiasco calls | outside `liberx/backend/fiasco/`, no object includes an `l4sys` header or contains a system-call trap other than erXos's, and no erXos source outside it references `l4_` symbols | syntax trees, disassembly |
| an architecture's terms appear only in its layer and its documents | `make check-arch-terms`: no term of an architecture's checked-in term list, `hw/arch_terms/<arch>.txt`, appears in generic sources, generic generated files, `abi/erx_abi.txt` or a generic design document; `kernel/arch/<arch>/`, `liberx`'s per-architecture directories, `abi/arch/<arch>.txt`, `hw/sysreg/<arch>.json`, the term list itself, the architecture's binding document, the platform binding, the research records and [design.md](design.md#dependencies)'s dependency table, which names every dependency, board firmware included, are exempt; an architecture's name is not one of its terms | text search |
| generated files are never edited | the drift check | regeneration |
| kernel C recurses only through `musttail` | the stack proof's cycle rule | disassembly |

The checks bind erXos's kernel and the C17 code erXos adds to the stopgap;
Fiasco's inherited C++ is exempt.

Helping has one funnel: only `erx_help_run` runs a preempted thread on a
CPU other than its home CPU, for a lock holder and for nothing else,
and it hands the thread back to its home CPU before the helper
itself waits or is switched out, so no thread's stack is ever runnable
from two CPUs (K14); the return-path check refuses a user-mode return
from a borrowed thread. A seeded violation fails the build, and the host
model checks the exclusivity independently of the source-location check.

### Stack proof

Every build proves the worst-case depth of every kernel stack from the
entry points that run on it. `tools/stack_proof.rb` reads the frame size
of every function from the `.su` files clang writes under `-fstack-usage`,
failing on a function without one, the declared stack use of each assembly
routine from `kernel/stack_targets.txt`, which it checks against the
stack-pointer adjustments in that routine's disassembly, failing on one it
cannot read as a constant, and the call graph of the linked image, which
every build links keeping the relocations that a final link otherwise
resolves and drops. The proof decodes every branch instruction of every
function itself, from `llvm-objdump -d -r`: a call adds the caller's frame
and a branch to the start of another function is a tail jump, which
replaces it, each only where the architecture's call or jump relocation
names the same target, and every other branch must stay inside its
function. So a direct call the proof cannot classify, a branch into the
middle of a function or an image without its relocations fails the build
rather than turning a function into a leaf; the binding names the
instructions, the relocations and the link option
([design-arch-aarch64.md](design-arch-aarch64.md#stack-proof)).

| Entry | The stack it runs on |
| --- | --- |
| boot, until the boot CPU's idle thread runs | the boot stack inside the image, which becomes that idle thread's kernel stack, `ERX_KSTACK_SIZE` |
| secondary boot | the CPU's idle thread's kernel stack |
| a kernel call, a synchronous exception from user mode, the idle loop | the running thread's kernel stack, `ERX_KSTACK_SIZE` |
| an interrupt, an asynchronous error | the kernel stack of the thread it interrupts, on top of whatever that thread's kernel path holds |
| a synchronous exception in kernel mode | the panic stack, 16 KiB: the kernel accesses no memory that may fault, so every such exception is a kernel bug and panics |
| a panic | the CPU's panic stack |

An interrupt is taken on the stack of the thread it interrupts, and
interrupt handlers never nest. A thread's worst case is therefore its
deepest path from the call, user-mode synchronous-exception and idle
entries, plus the deepest path from the interrupt and asynchronous-error
entries, wherever on the first path the interrupt arrives. A switch away leaves the frames
at the switch point on the thread's own stack and resumes another thread
on its own, so no path continues on another thread's stack. The build
fails on:

* a frame above 1 KiB, with no list of exceptions;
* a frame the compiler reports as dynamic, which the kernel cannot produce
  because it has no variable-length array or `alloca`;
* an indirect call whose targets `kernel/stack_targets.txt` does not list:
  the dispatch's call through the handler table lists the `erx_sys_*`
  handlers;
* a branch that leaves its function other than as a call or a tail jump
  with its relocation, which a negative test seeds by proving the same
  image linked without its relocations;
* a cycle in the call graph through anything but tail jumps;
* a thread's worst case, or a panic or boot path, exceeding its stack less
  a 1 KiB margin.

A tail call that the optimiser happens to make is a jump in the release
build and a call in the unoptimised one, so the proof runs on both, and
on every other kernel that is built, such as the one built with UBSan in
trap mode for `make check-ubsan`, since each configuration has frames of
its own: an
ordinary tail call is a call at `-O0` and a jump at `-Og` and `-O2`, and
a `musttail` call is a jump at every level (measured with clang 23.1.4,
2026-10-29; the binding names the instructions,
[design-arch-aarch64.md](design-arch-aarch64.md#stack-proof)). A cycle
that rests on the optimiser fails the unoptimised
proof, so only `musttail` recursion passes both. Kernel stacks have guard
pages: a fault on one is taken on the panic stack and panics, naming the
stack.

## Performance

**Cost model.** Measured figures are cited; the rest are estimates from
counting crossings and memory accesses.

| Operation | Cost | Basis |
| --- | --- | --- |
| a trap from user mode and its return; with an address-space switch | 22 ns; 31 ns | measured under HVF on the M4 ([research](research-baselines.md#exception-and-address-space-switch-costs)) |
| Fiasco's null call; one-way IPC in one space and between two | 29 ns; about 51 and 89 ns | measured under HVF on the M4; the IPC figures are converted from an emulated cycle counter at an inferred 3.072 GHz ([research](research-hierarchical-scheduling.md#fiasco-under-hvf)) |
| null kernel call (decode, one capability lookup, return) | 30 to 40 ns | estimate: the trap plus a lookup in a warm table |
| IPC call round trip through a gate on one CPU | 150 to 250 ns | estimate: two traps with address-space switches, two copies of a few words between UTCBs, two decisions; Fiasco's one-way IPC between two spaces measures about 89 ns |
| an IRQ trigger waking a parked executor of a group on the same CPU | 150 to 300 ns | estimate ([design-scheduler.md](design-scheduler.md#performance)) |
| an upcall and its resume | 100 to 200 ns | estimate: a frame of about 300 bytes written at a return to user mode, and one call that loads it back and checks it |
| a thread's kernel memory | about 13 KiB: its record, an 8 KiB kernel stack and a 4 KiB kernel-user page | estimate from the sizes above; an ERTS domain of 40 threads holds about 520 KiB |
| a fault that populates a zeroed page | 0.5 to 1 us | estimate: trap, plan, 4 KiB zero, entry write |
| `erx_vm_commit` of 1 GiB | one record and the reserve arithmetic, under 2 us, and the backing: 262,144 pages taken from the allocator into the space's pool in 4,096 parts of 64, a few milliseconds while pages are free, none of them zeroed or written | estimate: the buddy allocator's take per page, which `tools/erx bench mmap` measures; a page is zeroed only when a fault puts it in use |
| `erx_space_pause` until no thread of the space runs in user mode | the interrupts it sends, each taken within the longest stretch with interrupts masked, at most 20 us under HVF | estimate from K13's bound; `tools/erx bench pause` measures it, and `erx_space_quiesce`'s wait with it |
| the existence lock of one space under maps, range calls and destroys from four CPUs | an uncontended acquire of a helping lock, tens of nanoseconds, and helping beyond | estimate; `tools/erx bench locks` measures its contention and the helping it causes |
| `erx_space_stop` until the space's exit record | the walk, then the finishing threads' remaining parts, each on its own CPU within that CPU's finishing share (K18), then the exit records of the spaces below (K27); each part is preemptible, and the stopper sleeps meanwhile | estimate from K18 and K27; `tools/erx bench stop` measures a stop of a space whose threads are inside long range calls and in waits on every CPU, and of a tree of spaces |

**Budgets.** A null call at most 40 ns, an IPC round trip on one CPU at
most 300 ns, a fault that populates a page at most 1 microsecond, no
stretch with interrupts masked longer than 20 microseconds, all under HVF.
The conformance suite times each call; the benchmarks of
[plan.md](plan.md) measure the round trips with host, accelerator, QEMU
version, compiler, flags, workload and baseline recorded, TCG apart from
HVF.

**The borrowing chain.** A charge within a budget's guarantee takes that
budget's lock alone; a charge beyond it takes the locks of the chain up
to the first ancestor whose guarantee covers it. For a session's
programs that ancestor is the pool, so every commit a program makes
beyond its small guarantee takes the pool's lock, and programs that
commit at once on several CPUs serialise there for the chain's bounded
arithmetic, which has no preemption point. musl's `malloc` commits in
small steps, so a program that grows its heap takes the pool's lock
often. The cost is measured, not guessed: `tools/erx bench mmap` and
`tools/erx bench spawn` run with programs committing at once on four
CPUs, and a change to `erx_budget_adjust`, the chain or the floor comes
with before and after numbers from them. The first answer if the lock
shows is the session's policy giving each program a larger guarantee, so
that more of its charges stay within it; no mechanism in the kernel
serves it.

## Portability

AArch64 is the first architecture
([design-arch-aarch64.md](design-arch-aarch64.md)), and QEMU `virt` the
first platform, then the Raspberry Pi 4 Model B and the Raspberry Pi 5
([design-platforms.md](design-platforms.md),
[design.md](design.md#portability)). Boards sit behind the platform layer
(device-tree discovery, the interrupt controller and MSI frame, the timer,
UARTs, the real-time clock, the IOMMU, the boot random generator, the
watchdog, the firmware's mailbox, and the early console),
and processors behind the architecture layer, which implements the port
contract below. A port touches those layers only. The pure core is
portable C17 and builds for the host, which is how its tests, fuzz targets
and sanitizer runs work on macOS and Linux. `make check-arch-terms` keeps
each architecture's terms in its layer and its documents
([Chokepoint checks](#chokepoint-checks)).

### Port contract

What generic kernel code requires of an architecture. Each binding,
[design-arch-aarch64.md](design-arch-aarch64.md) for AArch64, maps every
item to its hardware, and a port is complete when its binding covers every
item, its files exist and the conformance suite passes on it.

| Item | What the architecture provides | What depends on it |
| --- | --- | --- |
| Modes | a privileged mode for the kernel and an unprivileged mode for every thread; any more privileged mode the CPU boots in is configured to trap nothing the lower modes need, and left for good | every isolation property; K12, K15 |
| Boot entry | a boot protocol: a header the loader reads, an entry with translation off and the device tree's physical address in a register, the boot image inside the first stage's file or as the initrd | [Boot](#boot) |
| Exception and interrupt entry | entries for a synchronous exception from user mode or kernel mode, an interrupt and an asynchronous error, on the running thread's kernel stack with interrupts masked, an entry from kernel mode saving its frame on that stack apart from the user registers; an exception return; the decode of a synchronous exception into a class, a cause and an address | dispatch, `erx_fault_classify`, the stack proof; K12 |
| Kernel stacks and the switch | a kernel stack pointer per thread, switched with the thread's callee-saved kernel registers at every switch; unmapped guard pages below each stack | [Execution model and locking](#execution-model-and-locking), the stack proof |
| System-call trap | one trap user code executes to call the kernel, distinguishable from another system's; registers for the call number, six arguments, the status and two results | [System-call dispatch](#system-call-dispatch); K13 |
| Thread state | the general registers, user stack pointer, program counter and user-visible status bits that a thread record and a vCPU upcall's frame hold; the thread-pointer registers, one of which user mode can read but not write, holding the address of the thread's kernel-user page; every other user-visible state saved per thread or trapped | `erx_thread_t`, [vCPU upcalls](#vcpu-upcalls); K15 |
| Translation | per-space tables over 4 KiB pages; a kernel half of global mappings and a user half; separate execute-never for user and kernel mode; no mapping writable and executable, in hardware where the architecture can enforce it; device memory attributes; constant-time faults on user accesses to the kernel half where available | [Virtual memory](#virtual-memory), `erx_pte_make`; K4, K8, K22 |
| Address-space tags and TLB maintenance | ASIDs wide enough to allocate with generations; invalidation of every CPU's TLB by page, of every level of the walk over a range, and by ASID, with a wait for completion; the rules for replacing a valid entry | K9 |
| Kernel access to memory | a direct map of all RAM in the kernel half, through which the kernel reaches UTCBs, shared areas and memory objects' pages; `erx_uword_load`, a walk of a space's translation tables through the direct map that yields a page the direct map covers or `ERX_EFAULT`, and one atomic 32-bit load of the word it finds; store tracking, either by a dirty state the hardware sets in a translation entry, read before the entry is freed, or by write protection and the permission fault | [Arguments and results](#arguments-and-results), [Umtx](#umtx), **Store tracking** in [Virtual memory](#virtual-memory); K7 |
| Timer | a per-CPU one-shot timer interrupt, and a monotonic counter with a known frequency, consistent across CPUs, that user mode can read without a call, in an order that keeps the read after the code before it | the scheduler's timer wheel, the time page |
| Interrupt controller and MSIs | masking, routing a line to a CPU, ending an interrupt, inter-processor interrupts, and an MSI frame for PCIe devices | [Interrupts, time and entropy](#interrupts-time-and-entropy), `erx_irq_step` |
| CPU start and machine end | firmware calls, through one routine, that start a CPU, turn the machine off and reset it | boot, `erx_machine_end`; K19 |
| IOMMU | streams per device, translation tables, a command queue with completion and a fault queue; invalidation by page and of every level over a range, with a specified completion observation, visibility domain and reclamation barrier; a valid stream entry that aborts without recording faults; rejection of unauthorized already-translated traffic; a memory-independent global abort for future traffic, separate from the loader's drain of outstanding DMA; a device the IOMMU does not cover, or that is on no fixed bus, is unconfined | [DMA and the IOMMU](#dma-and-the-iommu); K9 |
| FP and SIMD state | compiler flags that keep FP and SIMD instructions out of the kernel; the state to save on every switch; vector extensions that stay trapped | K10, K11 |
| Cache maintenance | making code coherent for instruction fetch; maintenance by address for non-coherent DMA; user-mode maintenance by address where the architecture allows it | the boot image, sealed code objects, JIT runtimes, drivers' DMA |
| Asynchronous errors | where the architecture reports errors asynchronously: masking, and the windows at the exit from user mode and after the kernel's device accesses that attribute them | [Interrupts, time and entropy](#interrupts-time-and-entropy); K12 |
| Optional hardening | pointer signing with per-space keys, and branch-target protection with guarded pages | `erx_space_copy`, `ERX_SEG_GUARDED`, `ERX_MAP_GUARDED` |
| Speculation mitigations | the mitigations Linux applies on the architecture, and their firmware calls | [Security](#security) |
| Hardware register sources | a machine-readable specification of the system registers | [Hardware register sources](#hardware-register-sources) |

A port adds `kernel/arch/<arch>/`, `liberx`'s trap stubs, `abi/arch/<arch>.txt`,
`hw/sysreg/<arch>.json` with its extractor, `hw/arch_terms/<arch>.txt`,
and its binding document; nothing above the architecture layer changes.

## Dependencies

| Component | Purpose | Licence | Status |
| --- | --- | --- | --- |
| Fiasco kernel `50bbe8a9`, with `bootstrap` `a4f4ad18`, `sigma0` and `l4sys` from `l4re-core` `e2e2d5af`, `libfdt` `5756062b` and `mk` `22cc26e5` | the stopgap kernel behind this interface | MIT (each package's `LICENSE.spdx`), with the GPL and LGPL parts listed above excluded, except the GPL-2.0 `kobject_rpc.h` and `jdb_object.cpp`, which the kernel needs, so no stopgap build is distributed outside the project; capstone in the kernel debugger is BSD-3-Clause-Attribution; the link closure of `bootstrap` and `sigma0` recorded at import | stopgap, replaced by erXos's kernel |
| libfdt | device-tree parsing in erXos's kernel | BSD-2-Clause (dual GPL-2.0-or-later) | permanent |
| BLAKE3's official C implementation | the boot image's index and file hashes, in its portable form in the kernel and `bootstrap` ([The boot image](#the-boot-image)) | CC0-1.0, Apache-2.0 or Apache-2.0 WITH LLVM-exception, used under Apache-2.0 WITH LLVM-exception | permanent |
| Arm's machine-readable A-profile architecture specification | the source of the AArch64 port's `hw/sysreg/aarch64.json` ([design-arch-aarch64.md](design-arch-aarch64.md#hardware-register-sources)) | BSD-3-Clause | permanent, as a pinned generator input |

erXos's kernel carries code derived from Fiasco under Fiasco's MIT notice,
as [The current implementation](#the-current-implementation-the-modified-fiasco)
describes. The dependency table of [design.md](design.md#dependencies) is
the authoritative list.

## L4 lineage

erXos's kernel keeps Fiasco's model wherever erXos needs nothing else:
capabilities as the only authority, held in a table per space; spaces
created by any holder of a factory; a kernel stack per thread in a
preemptible kernel with helping locks and cross-CPU requests; IPC gates
bound to one thread, with an open wait that receives from every gate and
IRQ object bound to the thread and tells them apart by label, and calls
with an implicit reply to the current caller; messages in a thread's UTCB,
with capabilities as typed items, a map copying and a grant moving; IRQ
objects that hardware lines, MSIs and software trigger alike; the subset
of the vCPU interface that delivers events to a thread; a delete right
that destroys an object for every holder; a hierarchy of quotas to which
every kernel allocation is charged; IRQ objects with MSI routing and DMA
spaces behind the IOMMU in the kernel, and PCI configuration in user
mode; and Fiasco's flat object space, in which each object keeps the list of
slots that name it, a copy adds a slot, a close removes one, a deletion
removes them all, and an object goes after an RCU grace period, with its
two locks: the one over its slots, and the existence lock that a
deletion invalidates and waits for.
Each row below names what Fiasco does, what erXos does, the reason, and
what keeping Fiasco's way would lose; its basis is *needed by erXos*,
*defensible* (a choice the reason supports but does not force), *follows
Fiasco* (erXos takes Fiasco's way, by the user's decision), or *decided by
the user*. No departure rests on taste alone.

| Mechanism | Fiasco | erXos | Why | What keeping Fiasco's way would lose | Basis |
| --- | --- | --- | --- | --- | --- |
| Finishing a stopped space's calls | kernel calls keep their original stacks through preemption and helping, a dying thread completes its kernel work before its return path ends it, and that work runs on the thread's own scheduling context | the same continuation model, with the work run at a finishing level above every urgency on the thread's own CPU, within that CPU's finishing share and outside every quota, charged for the accounting to the `finishing_ns` of the thread's own path, apart from its usage, and `erx_space_stop` sleeps, holding nothing, until the tree's record is posted; a waiter helps a dying holder as Fiasco's does, charged to the waiter | a stopped group may have no time left, and no grant may hold an exit record back; the share, a few words per CPU, bounds what finishing takes from a CPU's user threads, with no reservation, sponsor or queue | with Fiasco's way, a thread of a group at zero quota could keep its exit record from ever arriving, or a reservation outside the groups would have to run it | needed by erXos; a scheduling change, not a second teardown protocol |
| Capability values | the holder chooses each capability's index, through a user-level allocator; slots carry no generation, and Fiasco's object locking notes that an object replaced in the same slot cannot be told apart | the kernel assigns the slot, and the value carries the slot's generation; a slot retires before its generation wraps (K1) | a stale capability never names another object, whatever a domain's code does | the guarantee would rest on every domain's slot allocator | needed by erXos |
| Rights | object capabilities carry read, write, special and delete, three object-specific bits and a weak-reference flag, whose meaning each interface defines; memory carries read, write and execute | a closed set of named rights per type, declared in the ABI file and checked by the one lookup; copying (`DUP`) and leaving a space (`GIVE`) are rights | each operation names exactly the right it needs, and the generator closes the sets; memory alone needs more than a dozen | rights such as "may map but not supply" or "may move but not copy" would move into each object's protocol checks | defensible |
| Quotas and creating spaces | a factory is a quota: creating an object charges the factory used, a child factory's limit is charged to its parent, and a quota lives until its last charge is freed; any holder of a factory may create tasks | budgets form the same hierarchy, each allocating call naming the budget that pays, and any holder of a budget with `SPACES` creates spaces; an executable paged object or a JIT space needs `CODE`, which never leaves the system domain's table | creating spaces follows Fiasco; `SPACES` lets the system domain withhold space creation from a domain without withholding its allocations; the right to make code follows from the image (K8) | with no `SPACES`, every domain that can allocate could build spaces; with no `CODE`, any domain could make objects whose pages programs execute | follows Fiasco for creating spaces; defensible for `SPACES`; needed by erXos for `CODE` |
| Returning a quota | a child factory's whole limit stays charged to its parent until the factory itself is freed, once nothing is charged to it any more (`create_factory` and the factory's `operator delete` in `factory.cpp`); deleting a factory leaves the objects made through it | budgets are space banks, as in EROS: destroying a budget deletes every object charged to it and every budget carved from it, its guarantee and its borrowing return to its parent at once less what is still charged, which the parent counts until the destroy's walk has released it, and for its records until their grace periods have passed and their cache pages are released ([Budgets](#budgets)) | ending a domain is one call that takes back everything the domain made, whoever holds it, so its principal regains the domain's guarantee at once, less what the reaper has yet to free; what must outlive a domain is charged to a budget that outlives it, the domain's outer budget among them | an ended domain's objects would live as long as anyone held them, so its principal's capacity would return only when the last holder closed them, and restarting a domain would need capacity beyond the principal's limit | decided by the user; the stopgap builds no `Ram_quota` and charges whole pages through the same `erx_budget_adjust` ([design-stopgap.md](design-stopgap.md#budgets-and-the-ownership-of-pages)) |
| Sizing a quota | a factory's limit is fixed when it is created, its children's limits sum within it, and a factory spends only its own limit, so every process is a hard partition of its creator's memory | a budget has a guarantee, carved as a factory's limit is and never taken by another, and a cap beyond it, up to which a charge borrows the room of its ancestors, counted at each of them by one chain; its carver resizes both while it lives; a budget whose cap equals its guarantee is a hard partition for every charge, admitted or refused at itself, which every domain's is ([Budgets](#budgets)) | a program of a session gets a floor that lets it start and end, and spends what its siblings are not using, as a QNX process draws on the system's pool within `RLIMIT_AS`, so a session runs as many programs as fit rather than as many as their guesses fit, and a policy corrects a size without restarting what it sized; domains keep the partition, so a domain's memory depends on nothing but the kernel | a program would be refused while its session had memory free, or every program would be sized at the largest it might need and a session would hold a few; a wrong size would last as long as its holder | needed by erXos; the borrowing is EROS's and Fiasco's hard partition relaxed where the user asked, at programs |
| Memory | sigma0 owns physical memory at boot; user-level pagers map pages with flexpages when a fault arrives as an IPC (`thread-ipc.cpp`); map copies, grant moves, and unmap revokes through the mapping database; copy-on-write lives in user-level dataspace servers such as `moe` | memory objects with fixed ceilings, private memory with reserves, paged objects filled whole and sealed before any mapping, copy-on-write children, store tracking and copies of spaces, and a reverse map per object; there is no pager: every fault populates from its object or stops the thread (K4, K6), and none sends a message or waits; a mapping keeps its object, and an access to a deleted object's mapping faults to the fault gate | no fault waits on another domain, so an executor's fault never stalls its runtime and no domain can stall another's threads; a file server learns nothing of a program's layout; a file's shared mapping is its session's own shared object, written back from the pages the kernel reports stored; the runtimes and `liberx` stay simple, and erXos writes no region manager, since the kernel knows which object a faulting address maps | an executor that faulted would stall its runtime's scheduler until a pager replied; reserves and ceilings would be each pager's duty; Fiasco's message would show a pager every faulting address and instruction of its clients; Fiasco's page-fault IPC waits for ever | needed by erXos, by the user's decision |
| Execution model | a kernel stack per thread, in an 8 KiB block with the thread on 64-bit targets; a preemptible kernel with helping locks and preemption points inside long operations; a killed thread finishes its kernel work, then tears itself down on its own stack and waits out a grace period after its detachments (`Thread::do_kill`) | the same: a kernel stack per thread, a preemptible kernel and helping locks; long operations, such as removing a large run of capabilities, proceed in bounded parts between preemption points; a started call runs to its end, and a stopped or killed thread dies at its return to user mode with its waits cancelled, as `Thread::prepare_kill` arranges, a deleted thread tearing itself down there and waiting out a grace period after its detachments; the stack proof covers each thread's kernel stack with the interrupt path on top | erXos keeps Fiasco's model | nothing | follows Fiasco |
| Object lifetime | an object is destroyed in two phases: `destroy` marks it invalid, then after a read-copy-update grace period `put` drops the last reference (`kobject.cpp`); capability lookups take no reference, and reference counts cover only pointers between objects; each object has two locks: a helping lock over its slot list, which `lock_obj` takes without a counted reference, checking after each help that the slot still names the same object (`kobject_mapdb.cpp`), and an existence lock, which an operation that may pass preemption points holds after taking a counted reference and which a deletion invalidates and then waits to be free (`kobject.cpp`), so no mapping is inserted into a task under destruction (`Task::destroy`, `task.cpp`); a deletion empties every slot under the object's lock and then invalidates the existence lock (`kobject_mapdb.cpp`, `map_util.cpp`) | the same two phases and lookups, and the same two locks taken the same ways: the capability lock by `erx_object_lock_cap`, without a counted reference, looking the capability up again after every help, and the existence lock by `erx_object_lock_existence`, after a counted reference, held by every operation that changes an object across preemption points, invalidated by the object's destroy and then waited for, so nothing attaches to an object under teardown and no operation on it is still running; reference counts cover only threads that hold an object across a preemption point, never across a wait (K33), the stopgap's requester of a waited cross-CPU request being the one exception ([design-stopgap-scheduling.md](design-stopgap-scheduling.md#the-wait-funnel)), and every pointer from one object to another is an attachment of the target, which the target's teardown removes; one difference of order: the destroy invalidates the existence lock first, then clears the slots in bounded parts, and the one lookup refuses an object whose existence lock is invalid; an object's pages are released by its teardown and uncharged from then on, while its record stays until the reaper frees it | erXos bounds every stretch between preemption points (K13), so a long slot list is cleared in parts, and a deleted object must be unreachable from the first part (K26); the invalid lock is then the one mark that the lookup, the insert functions and the takers of the lock all read; an object dies with its budget (K3), which a counted pointer from an object of another budget would prevent | with Fiasco's order, a lookup would reach a deleted object until the last of its slots was cleared; with counted pointers between objects, an object could outlive its budget | follows Fiasco, by the user's decision; the order and the attachments needed by erXos |
| Two existence locks on one object | `Lock_guard_2` takes the one lock once when both pointers are equal (`lock_guard.cpp`), so a map whose source is the destination task proceeds (`Task::sys_map`, `task.cpp`) | `erx_object_lock_existence2` refuses two references to one object with `ERX_EINVAL`, before any lock | no call that holds two existence locks has a meaning on one object, and a refusal keeps one rule for the handler that takes them: each lock it took is one release | the handler would have to tell one lock from two at its release, for a case no caller wants | the design's own calls: a copy of a space onto itself has nothing to copy |
| IPC gates | a gate is bound to one thread with a label, whose two low bits carry the sender's rights on the gate; an open wait receives from every gate and IRQ object bound to the thread; a call leaves an implicit reply capability, and with the explicit-reply option, on by default, a task keeps a space of reply capabilities so that one thread can hold several calls; send and receive have separate timeouts | Fiasco's gates, open wait, implicit reply and two timeouts, as absolute deadlines; no donation, the server running on its own group's grant; capability passing at the rendezvous; labels are the binder's in all 64 bits; no explicit reply capabilities; a caller dropped because its server took another call, or whose server died, is woken with `ERX_EDEAD`, where Fiasco leaves the first waiting until its own timeout and the second waiting for ever (`Thread::do_kill` in `thread.cpp`) | erXos keeps Fiasco's model without its donation; no erXos server defers a reply past its next receive, and one that serves concurrently binds a gate to each of several threads; a server gives different authority through different gates; no caller waits for a reply no one can send | nothing erXos uses; explicit reply capabilities and rights in labels can be added behind the same calls if a server needs them | follows Fiasco; defensible for the subset and the dropped callers |
| Messages | a per-thread UTCB with 63 message registers, 504 bytes on 64-bit targets, holding the words and the typed items, and 58 buffer registers holding the receive items | Fiasco's message and buffer registers in the same 1 KiB UTCB; a receive accepts capabilities by count, at most four a message | erXos keeps Fiasco's model; the count follows from kernel-assigned slots (K1) | nothing | follows Fiasco |
| Call arguments | invocations take their arguments in registers and in the UTCB, which is kernel memory mapped into the task | the same, plus memory windows, each a memory object a capability names, an offset and a length, which the kernel reaches through its own mapping of the object's pages; no argument is a pointer the kernel follows, and the one call keyed by an address, the umtx wait, finds its word by a walk of the caller's translation tables ([Arguments and results](#arguments-and-results)) | the kernel can never be made to touch memory a domain names, or to fault on memory a domain unmapped (K7), so it needs no user-copy loops, no fixup table and no hardware switch that opens user memory to kernel mode | bulk data would cross in the UTCB alone, 504 bytes at a time | follows Fiasco for registers and the UTCB; needed by erXos for windows |
| Passing capabilities | typed items, each mapping or granting one capability into a window or slot index the receiver named; items go across one at a time, and a failing item leaves the earlier ones transferred; `Task::map` also lets a holder of two task capabilities map from one task to the other | typed items received into slots the kernel reserved for the receive, each with its generation; a pass is all or nothing and keeps each type's pass set (K24); only a space's creator, holding `CAPS` on it, installs into its table unasked: the system domain into domains, a domain into its sub-spaces | the kernel assigns slots (K1); a failed call changes no table; code, devices and the structure of spaces never pass; a table changes only at its own request or by its creator (A1) | receive windows would bypass the kernel's slot assignment; partial transfers would leave a sender to work out what moved; any holder of a space's capability could rewrite its table | needed by erXos for kernel-assigned slots and pass sets; defensible for all or nothing and creator-only installs |
| Closing and deleting | object capabilities are flat: a map makes an independent copy, an unmap removes only the caller's own slot, and an object dies when its last counted capability goes or a holder of the delete right deletes it, which empties every slot (`kobject_mapdb.cpp`); taking a capability back from one client means deleting an object of that client's own, as L4Re servers delete per-client IPC gates | the same: every copy is a slot of its own, a close removes one slot, and a deletion with `DESTROY` invalidates every capability at once and removes every mapping; per-recipient objects, such as the system domain's connection objects for each pair of domains, take something back from one holder; deleting a group kills its member threads and deletes its child groups, so no executor is left without a group to park in | erXos keeps Fiasco's model, and the stopgap uses Fiasco's object space as it is | nothing | follows Fiasco, by the user's decision |
| Deleted memory | an unmap removes a mapping and its descendants through the mapping database, and a later access faults to the thread's pager, which may map something else or kill the task | deleting a memory object removes every mapping of it; the records stay, marked deleted, and an access faults to the space's fault gate as `ERX_FAULT_DELETED`, which a program sees as `SIGBUS`; servers map only memory no client can delete and copy the rest with calls that fail instead | a fault on deleted memory goes to the fault gate, as every fault the kernel cannot resolve does; a server never maps what a client could delete, so deletion cannot be used to crash it | nothing: the access faults as in Fiasco, and only the receiver of the fault differs | needed by erXos, by the user's decision |
| Release signal | weak capabilities do not keep their object alive; a thread may register one deletion IRQ, which fires when any IPC gate bound to it is deleted, without saying which; L4Re servers hold weak capabilities to the gates they hand out and scan them when it fires | neither: the kernel tells no one of a release; the party that must know a holder's end is the one that installed the holder's capability, the system domain for a connection and a session for a pipe or a channel, and it learns the end from the fault gate or its own records ([design-domains.md](design-domains.md#connections), [design-pipes.md](design-pipes.md#making-a-pipe)) | every cross-space object erXos shares is installed by one party that also supervises both holders, so a signal from the kernel would tell it what it knows | nothing erXos uses; weak capabilities and a deletion IRQ can be added behind the same calls if a server ever hands out objects to parties it does not supervise | defensible |
| Pipes | no byte streams in the kernel; L4Re builds them from shared-memory rings and IRQ objects | no pipes in the kernel: a session builds each pipe from a ring in a shared memory object it maps into both programs' sub-spaces, with IRQ objects as doorbells, and installs every end itself ([design-pipes.md](design-pipes.md)) | the user's decision to keep pipes out of the kernel | nothing | decided by the user |
| Umtx | no address-keyed waits; a kernel semaphore object per waiter, as L4Re's pthread library keeps one per thread | umtx: waits keyed by a word's address, in the style of FreeBSD's `_umtx_op`, borrowing from Linux's futex where needed; the kernel finds the word by a walk of the caller's translation tables and reads it through its own mapping ([Umtx](#umtx)) | musl and ERTS synchronise through address-keyed waits; with a semaphore per thread every wait queue lives in user space, and a waker in another space needs a capability to each waiter's semaphore | musl's and ERTS's synchronisation would be rewritten around per-thread semaphores, as L4Re rewrote its pthread library | decided by the user |
| Doorbells | an IRQ object is bound to one thread at a time, with a label, and delivers each interrupt or software trigger as an IPC to that thread's open wait, which reports the label; deliveries queue among the senders at priority 255, the highest, in arrival order with senders of that priority (`ipc_sender.cpp`, `prio_list.cpp`); any holder of a capability to it may trigger it; at most one delivery is queued at a time, and triggers meanwhile count once; deleting it withdraws a queued delivery; a level-triggered line is masked at every hit, an edge-triggered one at a hit while unbound or while a delivery already waits, and at an unbinding, and the end of interrupt unmasks only when nothing is queued or pending (`irq.cpp`) | Fiasco's IRQ objects, with Fiasco's masking, end of interrupt and queueing at the highest urgency, triggered by software as doorbells, one per waiter and any number of senders, with rings saying which source has work; an IRQ object may also be bound to a scheduling group, with a label, so that it wakes the group's executors; a released IRQ object leaves one last delivery at its target, merged with one already waiting; a delivery withdrawn by an unbinding is owed to the next binding for a software object, an edge line or an MSI and dropped for a level-sensitive line, as Fiasco's `irq.cpp` does | executors never block in an IPC and wake by parking on their group; a waiter whose doorbell is deleted wakes once, whatever the order of the last ring and the close | nothing, beyond the binding to a group; with the queued delivery withdrawn, a last ring just before a close could be lost | follows Fiasco, the masking and the withdrawn delivery included; needed by erXos for the binding to a group; decided by the user for the last delivery |
| Faults | each thread has a pager and an exception handler, set through thread control by any holder of the thread's capability; a vCPU may take its page faults and exceptions as upcalls when its state word asks | each space has one fault gate and label, fixed when its creator creates it and served by the system domain for domains, by the creator or its designee for sub-spaces; the vCPU fault flags read as zero | a space's creator sees every fault and every end in one place (A2), and no code in a space can redirect them | a space could steer its faults away from its creator, and ends would be reported only by each space's own handler | needed by erXos |
| Ending a space | a task ends when its last counted capability goes or it is deleted; the kernel tells no one, and L4Re's parent protocol reports a program's exit at user level | stopping a space stops all its threads, and the kernel posts one exit record to the fault gate once no thread can return to user mode (K18) and every child's record is posted, as it does when the last thread exits; a space whose last capability goes stops; deleting a space deletes every space below it, where Fiasco's tasks are unrelated objects and deleting one leaves the others | crashes, halts and stops all arrive as records in one place, which supervision and the system domain's cleanup rely on (A2, A8); a space names its parent and K27 is a property of the objects, so no capability keeps a space below a deleted one | a crashed program could not report its end, and supervision would depend on each domain's cooperation; a party could keep another's records and tombstones for as long as it held one capability | needed by erXos |
| Space parents | tasks have no parent: a task lives while a counted capability names it | every space but the first has a parent, fixed at creation, stops when its parent stops, and reports its end only after its children; a space's capability leaves its creator's table with `INSPECT` alone | a program never outlives the session that started it, and no domain outlives the system domain, by construction (A8), whatever capabilities are held where; a sub-space stops with its creator at once, and every domain with the root task | a sub-space would run until its creator's table is emptied, A8 would rest on the system domain's records, and a domain could outlive the root task | decided by the user |
| Pausing a space | no pause of a whole task: a task's manager acts on its threads one at a time through their thread capabilities, and threads it does not know of keep running | holds on a space, honoured only at the return to user mode, where a stopped space's threads die, so every call and every kernel continuation runs to its end first; four states, each a fact the kernel establishes: user execution prohibited, at which a pause returns once its interrupts are taken; kernel mutation quiesced, which `erx_space_quiesce` waits for and a copy requires; outside writes resolved, by construction; and terminating, which a stop makes final; each hold is a ticket of its own, at most `ERX_SPACE_HOLDS` a space, so a session pauses a program's sub-space once per cause, the copy for `fork` among them, resumes each by its ticket, and a resume ends only what ran under its hold | a consistent snapshot for `fork` and a job stop that no thread escapes, without any party having to know every thread or to zero a group's grant, so the policy stays the one writer of grants; the boundary is where Fiasco already diverts a dying thread (`Thread::prepare_kill`), and no state waits for a party outside the space | `fork` would copy memory other threads are still writing; job control by grants lets a thread run to its next accounting point, and two writers of one grant undo each other | needed by erXos |
| vCPU | the vCPU interface: a state area per thread with the saved frame, an events-enabled flag, a sticky pending flag and an entry; incoming events delivered as upcalls while events are enabled and the thread is in no IPC; page faults and exceptions as upcalls on request; vCPU user mode running another task's address space | the subset `liberx` needs for signals: IRQ objects bound to an armed worker upcall into it, an armed umtx wait ends with `ERX_EINTR`, and a resume takes a pending event and re-enters the upcall in one step; faults never upcall, messages never upcall, executors are never armed, there is no user mode, and the kernel reaches the state area only through its accessors | POSIX signals through the L4 interface, while every fault still reaches the fault gate (A2), preemption never runs runtime code (K20), and an upcall never overwrites the message registers it interrupts; umtx is erXos's own | nothing for the subset; with Fiasco's fault flags, a thread could divert its own faults from its creator at any moment | follows Fiasco for the subset; needed by erXos for faults and executors |
| Scheduling | a scheduling context per thread: a fixed priority from 1 to 255 and a quantum, round robin within a level, and donation through an IPC that lapses at the next scheduling decision; senders queue at a receiver by priority, and nothing raises the receiver for them, so a server of clients at several priorities runs at the priority it was given | a tree of CPU groups with grants and quotas, 64 urgency levels, executors that park on their group, and no donation at all: every thread is charged to its own group, and a server runs on its own group's grant whoever called it; nothing raises a server for the callers queued at it, and one that serves clients of several urgencies is given a base urgency at their highest, beneath its group's ceiling ([design-scheduler.md](design-scheduler.md#service-work)); a wake leaves a thread on its home CPU, as in Fiasco, except with `ERX_GROUP_PLACE`, which M8 measures, where it looks for an idle CPU | the kernel allocates CPU time to runtime groups, and each runtime schedules its processes within its grants; a service's cost is its own group's, capped by policy, so no client can spend another group's time and no call carries a payer | the kernel could not enforce a runtime's grant, and a donation, even one that lapses, lets a client's time be spent in a server's group | needed by erXos; follows Fiasco for queued callers; decided by the user for no donation |
| Switching to a receiver | IPC switches directly to the receiver when it can, on the sender's time (`thread-ipc.cpp`) | the receiver is made ready and the ordinary pick runs, which may pick it; no switch goes past the pick | no call carries a payer, so a direct switch would need a rule for who pays until the next decision, and could run a receiver ahead of a more urgent ready thread | a direct switch saves one pick on a call within a CPU | needed by erXos; the stopgap's `activate_ipc_partner` does the same |
| Executors | every thread may block in any call | a thread's class is fixed at creation; an executor blocks only by parking on its group or in a umtx wait on a word in its own space's private memory, which only its own runtime's threads can wake, and the dispatch refuses it every other call that would wait, an IPC and a umtx wait on a shared object included ([design-scheduler.md](design-scheduler.md#executor-class-enforcement)) | a runtime's scheduler threads never wait on another domain in the kernel, while the runtime's own locks keep working, so its processes keep running | one waiting call by a scheduler thread on another party would stall every process it runs | needed by erXos |
| Device authority | sigma0 hands out device memory, an ICU capability binds any interrupt line or MSI, and PCI belongs to L4Re's user-level I/O server | IRQ objects with MSI routing and DMA windows bound through the IOMMU stay in the kernel, which makes the IOMMU abort every stream not bound to a window; PCI configuration belongs to a user-mode enumerator, an Erlang process, as L4Re keeps it in its I/O server; resource objects carved from the root resource name the device ranges, interrupt lines, BAR windows and requester ids the kernel hands out, and go to whichever domain the system configuration names | device authority is subdivided by the kernel, so a driver reaches only the ranges and lines carved for it, and bus mastering before a window is bound reaches nothing | device isolation would rest on sigma0's and the enumerator's discipline | follows L4Re for PCI; defensible for carved resources |
| Asynchronous errors | the handler counts each one per CPU and resumes (`thread-jdb.cpp`), with no containment | an error is contained at the device the platform's error records name, or at the thread a window presumes, its record marked as presumed, and the kernel panics only on an error the architecture reports as uncontainable ([Interrupts, time and entropy](#interrupts-time-and-entropy)) | a device's failed write must end something, at the narrowest boundary the hardware lets the kernel name (K12) | an error would pass unnoticed, and a device's failed write could corrupt a domain's state silently | needed by erXos for the containment; defensible for the presumption on boards without error records, which is provisional, for the user to confirm |
| Randomness | no entropy generator in the kernel | an entropy generator in the kernel, keyed at boot | the kernel randomises each space's placement and its object ids from boot | placement and object ids would be predictable, or would wait for a user-level service | defensible |
| Device secret | none: the kernel hands the root task no secret of the board | the platform layer reads a board's firmware key once at boot and hands the root task a device secret derived from it, on a read-only page no other space receives | the vault's `device` sealing backend needs a secret that the boot medium lacks, and only the kernel reaches the firmware's mailbox (PL2) | a board without a TPM module would have no secret beyond the medium, so whoever reads the medium could guess passphrases offline | defensible |
| Time | the kernel information page carries the clock and the memory map, and sigma0 maps it; a task's start-up data comes from its loader | a time page with monotonic and wall-clock time, mapped read-only into every domain, whose wall time the system domain sets; each domain's boot information page written by the system domain | runtimes read wall-clock time without a call | each wall-clock read would be a call to a time service | defensible |
| Boot | `bootstrap` loads the modules, sigma0 is the root pager and `moe` the root task, whose fault is a page fault to sigma0 or an exception to its handler while the machine runs on | the kernel validates the boot image and starts the system domain itself as the root task, with no root pager and no native root task beside it; every domain's space is a child of the root task's, so every domain ends with it | the boot image format is erXos's own, memory objects need no root pager, and one root holds policy and mechanism for domains in one place, Erlang policy over a C17 domain library | the boot image would carry L4Re's module model, and a native root task would hold a domain table of its own that a restart of the system runtime has to reconcile | needed by erXos; decided by the user for the system domain as root |
| The root task's end | a fault of the root task halts its thread or reaches its pager, and the machine stays up with nothing above the kernel able to act | a fault of the root task, its halt outside an ordered shutdown, and a missed watchdog deadline each write a crash record and end the machine through the panic path, by `erx.panic`, a reset in release builds (K31) | the root task holds the root authority and is every domain's parent, so nothing can recover it, and a reset with a record is the honest end, as OTP's `heart` resets a node whose runtime stops answering | a machine that is up with no root task, answering nothing, with nothing to reconcile and nothing to show for it | decided by the user |
| Watchdog | no kernel watchdog; L4Re leaves a board's watchdog to a driver | a kernel watchdog the root task pets, armed when the root task starts, with a boot deadline, whose missed deadline ends the machine after a crash record, and the board's hardware watchdog reloaded by the kernel from its own timer for as long as the kernel runs ([The watchdog](#the-watchdog)) | a hung system runtime is otherwise an up machine that answers nothing; the two timers have one owner each, so a kernel hang and a runtime hang both end in a reset and the runtime's never fires without its record | a hung root task would stay hung until a human resets the board | decided by the user |
| The ABI | hand-written `l4sys` headers | every call, right, status and layout generated from `abi/erx_abi.txt`, with a drift check ([The ABI file](#the-abi-file)) | one source for the kernel, `liberx`, the runtimes and Erlang | headers that drift from the kernel | needed by erXos |
| Code mappings | a flexpage may carry read, write and execute together, so a pager may map a page writable and executable | no mapping is writable and executable, and no page is executable while another mapping or a confined device can write it (K8): code lives in the boot image's slices and in sealed paged objects, and a JIT object is writable at one address and executable at another of its one space, which no other space and no device can map, its runtime publishing code by an explicit step | no code is writable where it runs, or anywhere else | a pager could map writable code, and a writable alias could change code a mapping executes | needed by erXos |
| Kernel debugger | JDB, an in-kernel debugger | none in erXos's kernel; inspection through `INSPECT`, the trace ring and the host's tools; the stopgap keeps JDB in development builds | less code and less to attack in kernel mode | interactive debugging in the kernel | defensible |

Notes:

1. **Fiasco's object capabilities are flat, and so are erXos's.** In
   Fiasco an object capability has no children: mapping it makes an
   independent copy, an unmap of the holder's own capability removes that
   slot alone, and the kernel keeps, per object, a flat list of every
   capability that names it, counting the counted ones, so that deleting
   the object or dropping its last counted capability empties every slot.
   Only memory mappings form a derivation tree, in the mapping database,
   which erXos replaces with memory objects. erXos keeps the flat model,
   and the stopgap uses Fiasco's object space as it is; seL4's capability
   derivation tree is the alternative erXos declines
   ([Alternatives considered](#alternatives-considered)).
2. **One worker, many sources.** An open wait receives from every gate and
   IRQ object bound to the waiting thread and tells them apart by label, so
   one worker serves many clients by binding one gate or one IRQ object
   per client to its thread, each with the client's label.
3. **Sizes.** Fiasco's mapping database with its map and unmap paths is
   3,478 lines (measured: `wc -l` over `mapdb.cpp`, `mapping_tree.cpp`,
   `mapping.cpp`, `kobject_mapdb.cpp`, the three `map_util` files and their
   two headers at `50bbe8a9`, 2026-10-31).

Sources for this section: Fiasco, https://github.com/kernkonzept/fiasco,
commit `50bbe8a981199e17865e8553a4eb02c387b339cf`, and the same files in
the L4Re snapshot `l4re-snapshot-26.09.0`: `src/kern/kobject_mapdb.cpp`
(the flat list per object, counted and weak capabilities, grant and
deletion), `map_util-objs.cpp` (object capabilities mapped without a
mapping database), `mapping_tree.cpp` and `mapping.cpp` (the pre-order
encoding and the 8-bit depth), `map_util.cpp` (unmap under the frame's
lock), `ipc_gate.cpp` (gates bound to a thread, labels with the sender's
rights in their low bits, the deletion IRQ), `thread.cpp` and
`thread_object.cpp` (pagers, exception handlers, `ex_regs`, the deletion
IRQ, `vcpu_control` and `vcpu_resume`), `receiver.cpp` (implicit and
explicit reply capabilities, the overwritten reply capability, upcalls
only outside an IPC), `reply_space.cpp` and `src/Kconfig`
(`EXPLICIT_REPLY_CAPS`), `thread-ipc.cpp` (items transferred one at a
time), `ipc_sender.cpp` (IRQ deliveries queued at the highest priority),
`irq.cpp` (binding, labels, triggers that count once while a delivery is
queued, and a queued delivery withdrawn at deletion), `vcpu.cpp`,
`context-vcpu.cpp` and `thread-vcpu.cpp` (the vCPU state, its entry into
kernel mode, fault upcalls), `switch_lock.cpp` and `context.cpp` (helping
locks), `semaphore.cpp`, `factory.cpp`, `ram_quota.cpp`, `task.cpp`,
`thread-pagefault.cpp`, `icu_helper.cpp`, `std_workload.cpp`, and
`config_tcbsize.h` (8 KiB kernel stacks on 64-bit), `src/abi/l4_types.cpp`
(63 message and 58 buffer registers, reply operations) and
`src/abi/l4_msg_item.cpp` (weak references). L4Re `l4re-core`, commit
`e2e2d5af9de7aa0e1df2a25ebadee54488fa4a49`: `l4sys/include/consts.h`
(unmap flags, grant, receive items, and the statement that object
capabilities are not hierarchical), `__l4_fpage.h`, `thread.h`, `ipc.h`
(open wait), `ARCH-arm64/arch/utcb.h`, `kip.h`, `l4re/include/parent`,
`libpthread/src/restart.h`, `moe/server/src/dataspace_noncont.h`,
`sigma0/server/src/memmap.cc`, and in the snapshot's `l4re-core`,
`l4re_itas/server/src/signals.cc` (no graceful cancellation of an IPC for
a signal). seL4,
https://github.com/seL4/seL4, master: `include/object/structures.h` (the
derivation tree's node inside each capability slot) and
`libsel4/include/sel4/constants.h`, read 2026-10-30 and 2026-10-31.
Fluke's latencies:
[research](research-hierarchical-scheduling.md#kernel-execution-models);
Fiasco's scheduling:
[research](research-hierarchical-scheduling.md#l4refiasco-source).

## Alternatives considered

**Keep the modified Fiasco as the permanent kernel.**

* *How it works.* Modify Fiasco until it implements the interface, and
  stop there.
* *Why it lost.* Fiasco's memory model of flexpages, a mapping database
  and user-level pagers is the opposite of memory objects with ceilings;
  its C++ is outside the construction rules; and it carries an in-kernel
  debugger, ACPI, hypervisor support and many options erXos does not use.
  The user chose a kernel of erXos's own, written in C17 on Fiasco's
  design: its process model, gates, UTCBs, IRQ objects and vCPU interface.
  The stopgap gets erXos running while that kernel is written behind the
  same interface.

**Fiasco's interface as erXos's interface.**

* *How it works.* Keep Fiasco's system calls, flexpages, UTCBs and
  capability layout, and make erXos's kernel binary-compatible.
* *Why it lost.* The interface would carry flexpages, capability slots
  chosen by user code and the `l4sys` layouts into every runtime. erXos
  keeps Fiasco's model (gates, the UTCB's layout, IRQ objects, the vCPU
  subset), but its calls, rights and layouts are generated from erXos's
  ABI file and owned by erXos, and the stopgap implements them.

**One kernel stack per CPU, the event model.**

* *How it works.* A thread that waits in the kernel leaves no kernel stack
  behind: a call that must wait records its wait and returns to the
  dispatch, the waker writes the results into the thread's saved
  registers, and a long call writes its progress into the caller's
  argument registers and is re-executed between bounded parts, as in
  Fluke's atomic interface.
* *Its merits.* A thread's whole state is its record, so it can be read,
  copied or destroyed at any moment; a CPU needs one kernel stack instead
  of one per thread, about 8 KiB each; a kernel that is never preempted
  needs no helping locks; and the stack proof covers one stack per CPU.
* *Why it lost.* The user chose Fiasco's process model, whose design and
  know-how the kernel reimplements. Every wait in the event model is a
  continuation written by hand, the shape of code in which the caller must
  get the order of steps right, while a thread in the process model waits
  where it stands. Its latency is as good as its restart points: Fluke
  measured worst-case latencies of 19.6 microseconds for its fully
  preemptible process model and 1,272 microseconds for its interrupt model
  with a single preemption point
  ([research](research-hierarchical-scheduling.md#kernel-execution-models)),
  and the process model gets the same bound from preemption points without
  re-executing calls.

**seL4 as the kernel.**

* *How it works.* Run erXos on seL4 with its capabilities and scheduling
  contexts.
* *Why it lost.* The user chose Fiasco's lineage and does not need seL4's
  formal verification; seL4's interface would become erXos's
  ([research](research-kernel-bases.md#sel4)). Its capability derivation
  tree is weighed on its own below.

**A derivation tree for every capability, as in seL4.**

* *How it works.* Every capability is a node in its object's derivation
  tree, kept as a pre-order list inside the slots as seL4 keeps it: a copy
  goes below its source, closing a capability removes everything derived
  from it, a separate revoke removes only the descendants, and a space's
  end removes everything derived from what it held, wherever it went.
* *Its merits.* A giver takes back a buffer or a gate it passed, with
  every copy made from it, without deleting the object and without an
  object per recipient; and a domain that ends takes back what it gave,
  so its objects never linger in other domains' tables.
* *Why it lost.* The user chose Fiasco's flat model. The tree is
  mechanism Fiasco does not have, so the stopgap would need a derivation
  list threaded through Fiasco's object space; every copy and move must
  keep the list's order and depth, and every removal walks a run under a
  held lock, with an exhaustive model of its own. erXos's targeted
  revocations already use an object per recipient, the system domain's
  connection objects for each pair of domains and a session's ring for
  each pipe, and the rule for servers means no server depends on taking back
  memory it mapped ([Closing and deleting](#closing-and-deleting)).

**Deleted memory that reads zeros.**

* *How it works.* When a memory object is deleted, or a capability it
  was mapped through goes, each CPU mapping of it is repointed at a page
  of zeros of its own space, never executable, so a server that mapped a
  client's buffer reads zeros, or what it wrote there itself, and never
  faults when the client takes the buffer back.
* *Why it lost.* It hides errors. An access to memory that is gone
  returns plausible data, so a bug or an attack shows up later as silent
  wrong data instead of a fault at the instruction that made the access.
  The denial of service it prevented, a client crashing a server by
  deleting memory the server mapped, is prevented by design instead:
  servers map only memory no client can delete, and copy the rest with
  calls that return an error ([Closing and deleting](#closing-and-deleting)).

**A counted reference on every lookup.**

* *How it works.* Every capability lookup takes a reference that the call
  drops when it returns, and a record is freed when its last reference
  goes, with no grace periods.
* *Its merit.* No grace-period machinery to write and prove.
* *Why it lost.* It adds an atomic write to every kernel call that names
  an object, on the hottest path, where Fiasco's read-copy-update lookups
  write nothing; erXos follows Fiasco's object lifetime, by the user's
  decision ([Execution model and locking](#execution-model-and-locking)).

**Endpoints served by several threads.**

* *How it works.* As in seL4, an endpoint queues callers and waiting
  servers, and any server thread takes any caller.
* *Why it lost.* The user chose Fiasco's gates, each bound to one thread.
  A server that wants several threads binds a gate to each, and its
  clients' gates spread over them; an open wait serves every gate and IRQ
  object of its thread, so one worker serves many sources by label.

**Recursive mapping with user-level pagers.**

* *How it works.* L4's flexpages: any space maps what it holds to others,
  and unmapping revokes recursively through a mapping database.
* *Why it lost.* Capabilities pass between spaces at a rendezvous, but
  mappings never do: a receiver maps an object only into its own space,
  through its own capability; a mapping keeps its object, and each
  object's reverse map finds every mapping of it when the object is
  deleted, with no mapping database, the largest part of Fiasco's memory
  code. No fault waits on another domain, since there is no pager.

**Capabilities queued in messages.**

* *How it works.* As with Zircon's channels and Unix's `SCM_RIGHTS`, a
  message carries capabilities into the receiver's queue, and the receiver
  takes them when it reads the message.
* *Why it lost.* A queued capability belongs to no table: queues can hold
  each other's ends in cycles no process reaches, which Linux collects
  with a garbage collector whose race, CVE-2021-0920, was exploited in the
  wild. Passing at a rendezvous leaves nothing in flight.

**Only the system domain installs capabilities.**

* *How it works.* Domains pass nothing; the system domain gives every
  capability a domain holds.
* *Why it lost.* The user chose to keep the mechanism: spaces that share
  a gate pass capabilities at a rendezvous within the pass sets, as a
  session and its programs and a domain and its sub-spaces do, and the
  kernel, which knows spaces and not domains, has no rule of its own for
  domains. Each reason for the restriction holds by construction without
  it: nothing is in flight, pass sets keep code, devices and structure
  with each space's creator, and the inspector sees every table. And the
  system's configuration shares no gate between two domains: the domain
  library installs no gate of one domain in another and no system
  manifest introduces one, so no capability passes between two domains
  and the restriction would forbid nothing that happens
  ([Rights](#rights)).

**Only the system domain creates spaces.**

* *How it works.* `SPACES` is the root budget's alone, so every space is a
  domain the system domain built and supervises.
* *Why it lost.* The user chose Fiasco's model, in which any holder of a
  factory creates tasks. A sub-space is contained by construction: it
  hangs under its creator, its capabilities never leave its creator's
  domain, it stops when its parent stops, and its faults go to its
  creator ([Creating spaces](#creating-spaces)). The system domain still
  creates every domain, because a domain's space must be a child of the
  root task's so that it ends with it.

**A separate native root task.**

* *How it works.* A small native program is the root task: it holds the
  root capabilities, creates every domain's space on the system domain's
  request, keeps a table of them, and restarts the system domain's runtime
  when it faults, so configured services ride through that fault.
* *Its merit.* A fault of the system runtime costs the machine a restart
  of one domain instead of a reset.
* *Why it lost.* Two instances of the system domain overlap in one budget
  during the restart; every configured registry needs identity and
  re-grant rules for the new instance; devices must be reconciled with
  drivers that outlived their policy; and the root task is a second
  trusted program with its own request protocol, ring and fuzz target.
  erXos takes the reset, as OTP's `heart` does, with a crash record so
  nothing is lost silently, and keeps the domain library behind one C
  interface, so a separate root task remains a change behind that seam
  ([The root task](#the-root-task)).

**Donating the caller's time to the server.**

* *How it works.* As in Fiasco's IPC direct switch, a call lends the
  caller's CPU time to the server until the reply, or, held until the
  reply, down a chain of nested calls, so each client pays for the service
  it receives.
* *Why it lost.* A thread would run on another group's time, which the
  kernel's grants could then not bound without a second accounting of
  payers and loans; a server's own grant, capped and sized by policy for
  the clients it serves, bounds the same cost with no mechanism in the
  kernel ([design-scheduler.md](design-scheduler.md#service-work)).

**A kernel maintenance reservation for finishing and reclamation.**

* *How it works.* Each CPU keeps a reserved share of time at a reserved
  urgency on which the calls of stopped spaces finish and the reaper
  runs, queued fairly, so a zero quota cannot stall them.
* *Why it lost.* It is a sponsor outside the groups, with an admission of
  its own: a reserved share to size, a queue to keep fair, and the
  reaper's and the finishers' claims on it to arbitrate. The finishing
  level and its share keep the one part that matters, that no grant can
  hold a death back, and drop the rest: the level reserves nothing and
  admits nothing, it caps what finishing may take from a CPU's user
  threads, in a few words per CPU; the reaper keeps its own rule, idle
  time and the reap deadline; and the accounting adds the finishing
  time to the stopped threads' own groups, apart from their usage, so
  there is no sponsor to size ([Execution model and
  locking](#execution-model-and-locking)).

**A release signal and tokens.**

* *How it works.* A holder of `DESTROY` sets a watch on an object, an IRQ
  object that fires when the object's last capability goes; a token is an
  object with one capability that exists to be watched, so moving it to a
  party and watching it tells the watcher when that party closes it or
  ends.
* *Why it lost.* Every object erXos shares across spaces is installed by
  a party that supervises both holders: the system domain installs a
  connection's objects and learns each domain's end from its fault gate,
  and a
  session installs every pipe end and channel and knows every holder from
  its own records. The signal would tell those parties what they know,
  at the cost of an object type and a field on every object
  ([Closing and deleting](#closing-and-deleting)).

**Thread interrupts of erXos's own.**

* *How it works.* A notification armed as a thread's interrupt source
  diverts the thread at its next return to user mode, saving its frame in
  a save area in its own memory, and a return call restores the frame.
* *Why it lost.* The user chose Fiasco's vCPU interface. Its subset gives
  the same delivery, with an atomic resume that takes a pending event, and
  a state area the kernel owns, so an upcall can never fault on a save
  area ([vCPU upcalls](#vcpu-upcalls)).

**Pipes in the kernel.**

* *How it works.* A pipe object holds a ring in kernel memory; writes and
  reads copy through a bounce buffer, and the kernel tracks each end's
  holders for the end of the stream.
* *Why it lost.* The user chose to keep pipes out of the kernel. A
  session builds them from shared memory and IRQ objects, with no copy
  through the kernel ([design-pipes.md](design-pipes.md)).

**Zircon's copy-on-write clones.**

* *How it works.* Any memory object can be cloned, clones of clones form
  trees, and a write to a page shared down a tree is resolved through
  hidden parent nodes, with pages attributed along the chains, evicted
  under pressure, or discarded when marked so.
* *Why it lost.* Its generality is most of the 40,774 lines of Zircon's
  virtual memory at f32 ([research](research-kernel-bases.md#zircon)).
  Shared code pages, private copies of data and snapshots need only one
  level of children over immutable parents, reserved in full at
  creation, which keeps the first-touch funnel to one decision and one
  installation and the accounting strict.

**Copy-on-write sharing of private memory for `fork`.**

* *How it works.* `fork` maps the parent's private pages read-only into
  both spaces and copies a page at the first write in either.
* *Why it lost.* A private page would be mapped twice, which breaks the
  rule that trimming never meets sharing (K5), and the copies would charge
  memory at a random write instead of at the call. `fork` copies eagerly,
  charged at the call. A cheaper `fork` stays an option: if a program's
  heaps and stacks were shared objects rather than private memory, `fork`
  could seal them and give each side children, at the cost of building
  POSIX heaps on objects that can be children.

**Mapping a child's untouched pages from its parent, read-only.**

* *How it works.* A read of a page the child does not own maps the
  parent's page read-only in the child's mapping, and the first write
  copies the page and replaces every such translation of it.
* *Why it lost.* A child may be mapped at any number of addresses in
  any number of spaces, so the replacement is a walk of the child's
  reverse map, input-sized, under other spaces' locks, inside a fault,
  which K13 forbids in one part; bounding it needs a transitional page
  state that concurrent faults help or wait on, and a lock order that
  lets a fault reach other spaces' tables. Copying at the first touch
  costs one page copy for each page a child reads and never writes,
  into pages the child holds already, since it is backed in full at
  creation, and keeps a fault to one object and one translation.

**Paged objects filled on demand.**

* *How it works.* A fault on a page of a read-only paged object asks its
  supplier for the page and waits, as Zircon's pagers do.
* *Why it lost.* For code and the sources of private mappings, a fault
  that waits on another domain would break K6 for no saving: the whole
  object is reserved at creation anyway. Filling before sealing keeps
  every fault on such an object bounded.

**Writable paged objects with a supplier in the fault path.**

* *How it works.* A file's `MAP_SHARED` mappings share one kernel object
  that its file server supplies: a worker's fault on a page not yet
  supplied becomes a page-fault IPC to the server, through a gate fixed
  at the object's creation and with a deadline, and the server writes
  stored pages back through calls that withdraw them, report them dirty
  and confirm each write-back under a supply generation.
* *Its merit.* Every session that maps a file shares the server's one
  copy, so stores are coherent across sessions at once, as on Unix.
* *Why it lost.* It puts a pager into the kernel's fault path: a fault
  that waits on another domain, with a deadline, a supply generation, a
  four-state page machine, an authenticated fault source so a server can
  tell its clients apart, and executors that may not use it at all, all
  for the one case of a file mapped shared by two sessions at once. A
  session's own shared object, filled by copies and written back from the
  pages `erx_mem_dirty` reports, gives POSIX's semantics within a
  session with no fault that waits; across sessions stores meet at each
  write-back, as on a network file system
  ([design-files.md](design-files.md#shared-mappings)).

**Resizing alone, with the runtime asking for more when refused.**

* *How it works.* Budgets stay hard partitions, resizable by their
  carver. A program's `liberx`, refused a commit, asks its session's
  handler for a larger budget over the channel and retries; the handler
  resizes the program from the session's free capacity.
* *Its merit.* No borrowing in the kernel: two counters and the chain
  stay out, and the kernel's accounting is today's.
* *Why it lost.* The round trip sits inside `malloc` and `mmap`, in a
  program's allocation path, where `liberx` must send a request and
  wait while holding `malloc`'s lock, with the signal rules of P5 and
  P7 to keep; a program that grows in small steps makes a request per
  step; the handler still has to guess a size at each request, so the
  guess moves from carving to every growth; and the handler's resize of
  one program takes memory from the session's free capacity, which is
  borrowing done in Erlang, one round trip at a time, with the same
  arithmetic the chain does in one lock. A runtime, whose commit
  failure ends its domain, could not use it at all. The chain is one
  function and no round trip, and what it adds is listed in the open:
  two kinds of budget, fixed at carving; a spending that a shrink can
  leave above the cap, with every charge that would raise it refused
  until it falls; a dead budget whose spending its nearest live ancestor
  counts until its tree has released it; a charge that ends at the
  release, so that the reaper is never in a charge's path; and a watch
  whose two ends are written under two named locks. Each is a rule with
  one owner, not a case at a charging call site.

**A shared pool without a budget per program.**

* *How it works.* Every program of a session charges the session's
  pool budget directly; a program has no budget of its own.
* *Why it lost.* No cap per program, no account of what each program
  holds, and a program's end would no longer be one destroy that takes
  everything it made, which P9 and the session's `fork` and `exec`
  paths rest on. The guarantee and cap keep the budget per program and
  add the pool's behaviour to it.

**A cap on `used` alone.**

* *How it works.* The cap bounds what is charged to the budget itself,
  not what it guarantees to its children or what they borrow through it.
* *Why it lost.* A program holding `SPACES` would carve sub-space
  budgets and spend past its cap through them. The cap bounds the
  spending, which counts both, so a tree's cap holds by construction.

**A right of its own for resizing.**

* *How it works.* A `RESIZE` right, placed in the carver's slot beside
  `DESTROY`.
* *Why it lost.* Resizing is less than destroying, and `DESTROY` already
  marks the carver and reaches a holder only by the carver's own pass
  (K2); a second right
  placed at carving would widen K2's one rule for no case where someone
  may resize but not destroy, or destroy but not resize.

**Budgets that objects keep alive.**

* *How it works.* Every object holds a counted reference to the budget
  that paid for it; a released budget returns its free capacity to its
  parent at once and each remaining charge as that charge is freed, and
  objects others still hold outlive the domain that made them.
* *Its merit.* A receiver keeps what it was given after its giver ends,
  with no rule about where shared memory is charged.
* *Why it lost.* Ending a domain would not end what it made: anything a
  holder never closes stays charged for ever, the capacity comes back
  piecemeal, a released budget drains for as long as its longest holder
  keeps anything, where a destroyed budget's tombstone waits only for
  calls already under way to reach their next part, and objects that
  point at each other across budgets need counted references that keep
  both alive. Space banks make ending a domain one destruction, and the
  outer budget gives what others map a life of its own
  ([Budgets](#budgets)).

**Backing a reserve at the fault.**

* *How it works.* A commit charges its reserve and takes no page; the
  fault that first touches a page takes one from the allocator, freeing
  released pages or waiting a grace period when none is free, which the
  budget arithmetic says exists.
* *Why it lost.* The fault then allocates under the owner's lock, or
  outside it and revalidates against a race, and a page taken for a
  promise that another CPU filled meanwhile has to go back; a table
  dropped under a live commitment has to be charged again, which can be
  refused, or kept uncharged; and a fault that waits for the head
  batch's grace period can lose the pages other CPUs free to their own
  faults, so one domain's churn can starve another domain's fault for as
  long as the churn lasts. Backing the reserve in the call that charges
  it removes every one of these: a fault takes from its own pool under
  its own lock, a table goes only with its promise, and a backing never
  loses what it took. The cost is the allocator's take per page in the
  call that commits, in bounded parts, where a lazily backed commit
  touched no page ([Performance](#performance)).

**A ticket queue for page allocations on a full machine.**

* *How it works.* Allocations that find no free page take tickets and
  are served in order from what the reaper frees, by a wait queue and a
  handoff into the allocator.
* *Why it lost.* A ticket holder whose promise another thread of its own
  space filled meanwhile holds a place it cannot use until it runs, so
  the holder behind it waits on that thread's scheduling, which is a
  wait on a party; and with reserves backed at the charge there is no
  allocation to order: a backing takes released pages for itself and
  waits only for their grace period ([The reaper](#the-reaper)).

**A user-copy funnel.**

* *How it works.* Calls take pointers into the caller's memory, which
  the kernel reads and writes with the architecture's unprivileged load
  and store forms, recovering from a fault through an exception-fixup
  table that runs the fault decision and retries, with the hardware's
  privileged-access-never, or user translations switched off, keeping
  ordinary kernel accesses away from user memory.
* *Its merit.* Arguments of any size and shape, as on Unix.
* *Why it lost.* The kernel would touch memory a domain names, take
  faults in kernel mode that may populate pages and pass preemption
  points, keep a fixup table and a per-core isolation scheme, and order
  every call so that a fault leaves nothing done. Registers, the UTCB and
  memory windows carry every argument erXos has, with no kernel access
  that can fault ([Arguments and results](#arguments-and-results)).

**An existing archive format for the boot image.**

* *How it works.* The packer writes, and the boot validator reads, a
  format that already exists, so its tools can list and unpack images.
* *Its merit.* Existing tools, and no format of erXos's own to specify.
* *Why it lost.* The boot image needs an index read without scanning the
  data, every file on a page of its own so runtimes map it in place,
  64-bit sizes, the system and seal marks, image manifests, a hash per
  file and one over the index, and a reader small enough to check whole in
  a few hundred lines with no recursion. Each candidate misses some of
  this:
  * *cpio `newc`* and *tar* have no index, so finding a file scans every
    header before it; they align data to 4 and 512 bytes, carry POSIX
    owners, modes and times that erXos does not use, allow a name to
    appear twice with the later copy winning, and `newc`'s sizes are 32
    bits; the `crc` variant of `newc` sums bytes and detects little.
  * *ZIP* keeps its directory at the end and repeats each entry's name and
    sizes in a local header, which a reader must reconcile; its data may
    overlap and is compressed by default; 64-bit sizes need the ZIP64
    extension; alignment needs padding in an extra field, as Android's
    `zipalign` adds; and its CRC-32 is per file only.
  * *squashfs* is compressed in blocks, so nothing maps in place, and is a
    file system with inodes, directory tables and fragment tables: a
    parser far larger than the boot validator.
  * *ISO 9660* stores data in 2,048-byte sectors, needs Rock Ridge or
    Joliet for usable names, and records sizes in 32 bits, with
    multi-extent files beyond that.
  * *UBIFS* is a writable, journalled flash file system over UBI, with
    compression: the opposite of an image that never changes.
  * *EROFS*, uncompressed with 4 KiB blocks, maps in place and is what
    the system release uses from M6, inside a minimal `ERXPACK` whose
    files carry the EROFS images' root hashes
    ([design-storage.md](design-storage.md#system-updates)). As the boot
    image itself it would put a file system's inodes, directories and
    extended attributes into the kernel's boot validator, and it has no
    place for the marks or manifests.
  * *U-Boot's FIT* is a device tree whose nodes hold the images, with a
    hash per image and signatures over configurations. It would reuse the
    kernel's `libfdt`, but its data is not page-aligned unless stored
    outside the tree, its node names are not paths, erXos's marks and
    manifests would be properties of its own anyway, and its signature
    rules are U-Boot's, made for a loader rather than a kernel.
  * *QNX's IFS* is the closest in design: a flat table of records, page
    alignment as an option, a startup header that names the boot program
    and a script, POSIX metadata, 32-bit sizes, an additive checksum over
    words, and data ranges that may overlap, with a later record of the
    same name shadowing an earlier one
    ([the owner's IFS reader and writer](https://github.com/stass/fsimg),
    whose `specs/design-ifs.md` describes the format, BSD-2-Clause).
    erXos keeps the flat table and changes the rest: every file starts on
    a page; a BLAKE3 hash per file and one over the index replace the
    additive sum, which a two-bit change can cancel; one `root_entry`
    index and one fixed kernel path replace the boot and script
    references, and the system configuration, a file in the ABI file's
    record format, replaces the script; entries carry a kind and marks and
    no owners, modes or times, since authority comes from grants; sizes
    and offsets are 64 bits; and data ranges tile the archive in entry
    order and paths ascend strictly, so no range overlaps another and no
    name shadows another.
  * *Fuchsia's BOOTFS* is flat and page-aligned, a directory of names,
    offsets and sizes, and the closest to `ERXPACK`'s shape; it carries no
    marks, no manifests and no hashes, which `ERXPACK`'s entries add.

**One hash over the whole archive.**

* *How it works.* The header holds one hash over every byte, with that
  field read as zeros, and the validator checks it in its pass at boot.
* *Its merit.* One field and one check, and an identity for the host
  tool.
* *Why it lost.* The boot would read and hash the whole image before
  anything runs, tens of MiB at boot for files most boots use only in
  part, and a later image left on a memory-mapped medium would be read
  whole at every boot. The two-level hash keeps the one identity, since
  the index's hash commits to every file's, and moves each file's cost
  to its first use, where a damaged file is refused without stopping the
  boot.

**SHA-256 for the boot image's hashes.**

* *How it works.* The index and file hashes are SHA-256, which the
  kernel also has for the device secret's HMAC.
* *Its merit.* A standard that every tool computes, and one hash
  function fewer in the kernel.
* *Why it lost.* erXos's own validator and host tools are the only
  consumers of these hashes, so no outside tool needs to recompute them,
  and in scalar code, which is all the kernel may run, BLAKE3 is roughly
  two to three times as fast (an estimate), which matters for every file
  the boot checks. A platform's trust root that checks the slot with
  SHA-256 checks the whole file in any case.

**Files checked in user mode.**

* *How it works.* The system domain, or a checker domain, hashes each
  file with the architecture's SIMD instructions before it hands the
  file's slice on.
* *Its merit.* SIMD hashing is several times faster than the kernel's
  portable code.
* *Why it lost.* A user-mode checker must map the file to read it, so a
  damaged file would be mapped before its check, and the property that no
  file is mapped before its check would rest on every slice's holder
  checking first, a list of callers, rather than on the one call that
  makes slices.

**The boot image only as the loader's initrd.**

* *How it works.* Every platform boots two files, the kernel and the
  archive, and the loader places the archive and names it in `/chosen`.
* *Its merit.* No locator, and the kernel file never changes once built.
* *Why it lost.* Each slot would carry two files that must be paired, the
  Raspberry Pi firmware would need a configuration line naming the
  archive, and where a loader places an initrd differs between loaders
  and is confirmed board by board. The single file needs only the one
  file every loader already loads, and the two-file form stays for
  debugging under QEMU, where pairing is the point.

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| hashing each file with portable code at its first slice lengthens the boot and each domain's first start | medium | boot time, in proportion to the bytes the boot uses | each file is hashed once per boot and only when used; the boot benchmark reports the hashing time per platform, and the boot image stays small, with the system release in EROFS images from M6 |
| a loader places the device tree or another payload inside a large single file, because it ignores the declared image size | low | the boot stops with the locator's overlap check | the file's own extent covers the archive whatever the header says; the boot probe confirms each board's placement before anything depends on it ([design-platforms.md](design-platforms.md#boot)) |
| the stopgap's modifications grow large (memory objects, sealed paged objects, groups, the stop core in Fiasco's C++) | medium | the stopgap takes longer than expected | the stopgap carries only the part of the interface that the plan's vertical slice uses, and every mechanism beyond it lands on erXos's kernel alone ([The current implementation](#the-current-implementation-the-modified-fiasco)); the C17 cores are shared, so work done for the stopgap is work done for erXos's kernel; the plan's pilot calibrates the effort |
| the stopgap carries GPL code: `kobject_rpc.h` and `jdb_object.cpp` in the kernel, and possibly a link dependency of `bootstrap` or `sigma0` | certain for the two files | nothing built on the stopgap is distributed outside the project | recorded at import; erXos's kernel takes code only from files whose effective licence is permissive, judged by Fiasco's `LICENSE.spdx`, each file's own notice and its upstream history, and needs nothing those two files do: its dispatch is generated, and it has no kernel debugger ([design.md](design.md#dependencies)) |
| 8 KiB kernel stacks do not hold the proven worst case with an interrupt on top | low | larger stacks, about 4 KiB more per thread | the stack proof fails the build first; Fiasco runs in 8 KiB with its thread record in the same block |
| deleting an object that has many capabilities or mappings takes many bounded parts | low | a long call for the deleter | closing makes the object unreachable in the first part, so no other call waits for the rest, and the drain waits only for the one operation that holds the existence lock; each part is bounded and preemptible |
| a space's existence lock serialises its range calls and maps, as Fiasco's serialises a task's maps | medium | a runtime's threads that change their space's ranges at once wait for each other | faults do not take it, and every part is bounded; if `tools/erx bench` shows contention, a shared mode for operations, with the destroy's close and drain alone exclusive, is a change behind `erx_object_lock_existence` |
| a grace period lasts long while a CPU runs a long kernel path | low | released memory returns late, and the backing of a charge on a full machine waits for it | every path is bounded between preemption points (K13), idle and user-mode CPUs are quiescent at once, and a backing that needs a released page takes it off the list and waits its periods out itself, fewer than two, each bounded by the longest part, never on a party ([The reaper](#the-reaper)) |
| the budgets of a session's programs borrow through one pool budget, whose lock every charge of the session beyond a program's guarantee takes | medium | programs that commit at once on several CPUs serialise on the pool's lock, a heap that grows in small steps most of all | a charge within a program's guarantee takes the program's lock alone, and the chain holds its locks for bounded arithmetic with no preemption point; `tools/erx bench mmap` and `tools/erx bench spawn` with programs committing at once on four CPUs measure the cost, and a change to the chain or the floor comes with before and after numbers from them ([Performance](#performance)); if the lock shows, the session's policy gives each program a larger guarantee, which needs no new mechanism |
| the backing of a charge on a machine with no free page takes released pages on its own time, whoever released them | low | a creation or commit call on a machine with no free page waits fewer than two grace periods for each 64 pages it needs, and a domain that churns pages imposes that on every other domain's charges meanwhile; faults never pay it | the cost is bounded by the charge's own size, idle CPUs free released pages ahead of anyone, and no charge is ever refused for memory that is released; `tools/erx bench mmap` under a churning domain measures it ([The reaper](#the-reaper), [Security](#security)) |
| the vCPU subset leaves a signal waiting while a worker is inside a long call | low | a late signal | `liberx`'s long waits are umtx waits, which an event ends, and its calls carry deadlines ([design-programs.md](design-programs.md#signals-in-liberx)) |
| the MSI frame behaves differently under TCG and HVF | low | MSI drivers | one path for both, tested on both |
| an IOMMU's synchronisation completes before every transaction translated through the invalidated entries has | low | DMA into a page the kernel has reused | the binding cites the IOMMU specification's rule for the completion of invalidations ([design-arch-aarch64.md](design-arch-aarch64.md#iommu)); a board test unmaps a buffer under continuous DMA and checks that the device's writes stop before the page is reused; an IOMMU that never completes keeps its pages from reuse |
| a stop whose finishing work is large ties up the stopper's thread for its length | medium | a domain service thread that stops a domain with threads inside long deletions waits for them, for up to `ERX_FINISHING_PERIOD / ERX_FINISHING_TICKS` times their remaining parts, since the finishing share spreads the work over each CPU's periods | the work is bounded by records the stopped tree's budgets paid for, each part is preemptible, no grant lengthens the wait, and the system domain's `liberx` makes the stop from a thread that nothing else waits on ([design-runtime.md](design-runtime.md#the-root-task-entry)); `tools/erx bench stop` measures a stop under long range calls |
| the watchdog's deadline is too short for a system runtime under load, or under TCG | medium | a reset of a machine that was merely slow | the deadlines are `erx.watchdog`'s, the harness sets `D` and `B` larger for TCG runs, the pet comes from a system process that does no I/O, and the boot deadline `B` is separate from `D`, so a slow boot races only `B` ([The watchdog](#the-watchdog)) |
| a kernel booted on a board it was not built for writes its build's console address before the device tree is checked | low | a foreign device's registers written before the boot stops | accepted: the board build is the configuration, and the check against `/chosen/stdout-path` stops the boot at the early pass ([Console, log and panic](#console-log-and-panic)) |
| a region that survives a warm reset is scribbled by firmware or the previous boot | low | a crash record misread | the record carries a magic, a version, a length and a CRC, and its check has a fuzz target; a record that fails the check is reported as absent, never shown ([The root task](#the-root-task)) |

Open questions:

* **Which subsystem does the pilot build first?** Recommended: the
  capability table with its slot lists and lookups, and budgets, which are
  host-built and exercised by every call, so the pilot calibrates the
  plan's estimates with tests and sanitizers.
* **Whether a record's cache page stays charged through the record's
  grace period.** Recommended: yes. A record is memory a call in
  progress may read, and releasing its page at the destroy would make a
  free wait on a counted reference another party holds, which is a wait
  on a party; the cost is the cache pages of destroyed records, kernel
  records alone, for their grace period, the reap deadlines their
  backlog needs and a part, a round more for each level of a chain, and
  beyond that only the pages holding records that a call in progress
  keeps, which
  [Security](#security) bounds
  ([Budgets](#budgets)).
* **Choices made provisionally, for the user to confirm.** A space's
  capability leaves its creator's table with `INSPECT` alone, so `CAPS`
  has one holder (K17); a deletion closes an object before it
  empties its slots ([Closing and deleting](#closing-and-deleting)); the
  device-secret page, which the kernel derives at boot and hands the
  root task ([The root task](#the-root-task)); and a late asynchronous
  error on a board
  without error records, such as the Raspberry Pi 4, stops the thread its
  window presumes, its record marked as presumed ([Interrupts, time and
  entropy](#interrupts-time-and-entropy)), rather than containing the
  board's devices. The [L4 lineage](#l4-lineage) records all but the first
  as departures, with Fiasco's way as the alternative.

Decided by the user: a copy-on-write child copies a page at the first
touch of it through a mapping, a read as well as a write, so that no
translation of a child ever names a page of its parent and a fault does
one page's work however many mappings the child has, at the cost of one
copy for each page a child reads and never writes ([Copy-on-write
children and copies of
spaces](#copy-on-write-children-and-copies-of-spaces)); a dead budget is
inspected by nobody, since its capabilities fail the lookup from its
close, what it still holds showing in its nearest live ancestor's `used`
and `pinned` ([Budgets](#budgets)); a stopped tree finishes at the
finishing level on its threads' own CPUs, within each CPU's finishing
share of 4 of every 8 ticks and outside every quota, its time added for
the accounting to a separate `finishing_ns` counter of the finishing
threads' own groups, never to the killer's, with the stopper sleeping
until the record, where a helping phase would have run the finishing
threads on the stopper's CPU and passed their ownership along a chain of
stops, and a grant-funded finishing would have let an exhausted, frozen
or misplaced grant hold a death back (**The kill**, [Execution model and
locking](#execution-model-and-locking)); an object
under construction is owned by a construction record on its budget's
list from its first charge, whose existence lock its creator holds, so a
budget's destroy cancels and helps it as it drains any charged object,
at the cost of one cache record per creation, freed through the reaper
(**Construction**, [The reaper](#the-reaper)); and a hold on a space is
a ticket, so resuming one ends only what ran under it (**Pausing a
space**, [Threads and faults](#threads-and-faults)).

Decided by the user as well: spaces have parents, so a sub-space stops with its
creator and A8 holds by construction; a released IRQ object leaves one
last delivery at its target; groups have no signal call, since IRQ
objects bound to them are their doorbells; a group-bound IRQ object is
taken from the group's ready list, never received by a worker's open
wait; `CODE` travels only with budgets the system domain carves;
the system domain is the root task, its fault, halt and missed watchdog
deadline each ending the machine after a crash record; no call lends CPU
time, and a stop's tree finishes at the finishing level within each
CPU's share, charged for the accounting to its own groups'
`finishing_ns`;
budgets are space banks, so destroying one deletes everything charged to
it; `ERX_BUDGET_DEPTH_MAX` is 16, since programs' budgets do not nest and
the chain's locks are held together; `erx_budget_watch` stays, since
without it the only signal of a budget nearing its cap is the refusal
itself; a cap may be set below the spending, as `setrlimit` sets a limit
below the current use; no fault waits on a pager; capabilities
are flat, as in Fiasco; deleted memory faults; and objects die as in
Fiasco, after a grace period, with Fiasco's two locks, the capability
lock and the existence lock, the order of the close being the
provisional choice above.

## References

* Fiasco, https://github.com/kernkonzept/fiasco, commit `50bbe8a9`
  (2026-10-14), and the L4Re snapshot `l4re-snapshot-26.09.0`:
  `src/kern/context.cpp`, `context-vcpu.cpp`, `thread-ipc.cpp`,
  `thread-vcpu.cpp`, `thread_object.cpp`, `receiver.cpp`, `ipc_gate.cpp`,
  `irq.cpp`, `vcpu.cpp`, `switch_lock.cpp`, `ready_queue_fp.cpp`,
  `sched_context.cpp`, `ram_quota.cpp`, `vlog.cpp`, `config_tcbsize.h`,
  `src/Kconfig`, `src/abi/l4_types.cpp`; `LICENSE.spdx`; the full list
  behind each claim is in [L4 lineage](#l4-lineage).
* L4Re `bootstrap` `a4f4ad18`, `l4re-core` `e2e2d5af`, `libfdt` `5756062b`,
  `mk` `22cc26e5`, https://github.com/kernkonzept; licence declarations in
  each package's `LICENSE.spdx` (read 2026-10-29); `l4re_itas`'s
  `server/src/signals.cc` in the snapshot.
* seL4, https://github.com/seL4/seL4, master:
  `include/object/structures.h` (read 2026-10-30).
* FreeBSD `_umtx_op(2)` and `sys/kern/kern_umtx.c`, for the umtx
  interface.
* The architecture's and the boards' specifications, Linux's sources for
  their conventions, and the firmware the boards run:
  [design-arch-aarch64.md](design-arch-aarch64.md#references) and
  [design-platforms.md](design-platforms.md#references).
* B. Ford et al., "Interface and Execution Models in the Fluke Kernel",
  OSDI 1999.
* J. S. Shapiro, J. M. Smith and D. J. Farber, "EROS: a fast capability
  system", SOSP 1999, for space banks.
* [research-hierarchical-scheduling.md](research-hierarchical-scheduling.md),
  [research-kernel-bases.md](research-kernel-bases.md),
  [research-baselines.md](research-baselines.md) and
  [research-prior-art.md](research-prior-art.md) for the facts and
  measurements cited above.
