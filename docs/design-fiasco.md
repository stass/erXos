# erXos on Fiasco

erXos's first release runs on Fiasco, with every user feature, and erXos's own kernel replaces it
later behind the same interface. Fiasco, near stock, is imported under `fiasco/`, and
`liberx/backend/fiasco` implements erXos's calls on it, in user mode. This backend is the current
implementation behind an interface erXos owns: the generated C functions of
[design-runtime.md](design-runtime.md#the-liberx-interface), defined by
[design-kernel.md](design-kernel.md). At M7 the `erx` backend replaces it and nothing above
`liberx` moves. Fiasco is a kernel target erXos ships on, not only a stand-in for development: the
backend uses Fiasco's own mechanisms wherever Fiasco has them, and what Fiasco does not give is one
list of downsides of running on Fiasco against erXos's kernel, stated to users, not engineered
around.

One construction carries the document: **the root creates and places, Fiasco checks every use.**
The root service is the only creator of kernel objects and the only writer of any task's object
space and page tables. It creates each domain's objects through that domain's own Fiasco factory,
records what it made, and places a capability into the holder's object space at a slot it picks,
with the Fiasco rights that erXos's rights for that holder allow. Every use of a placed object (a
doorbell's trigger, a wait, a semaphore, an interrupt's acknowledgement) is the holder's own Fiasco
invocation of its own slot, which Fiasco checks; the root is not on that path. A handle is not a slot: it
names an entry of its holder's one handle table, which the root keeps, by the entry's number and
generation, and the entry holds the object's record, the record's generation and the holder's
rights ([Handles](#handles)). Of the objects a handle names, only an IRQ object is also placed in
the holder's object space.

Four constructions follow from it and carry the backend's detail:

* **One owner, one thread.** The root task creates every Fiasco object and holds a capability to
  each, owns every page, and alone places capabilities and mappings in other tasks; one thread of
  it, the root service, alone touches the tables that record them. Every other thread, the root's
  included, invokes the objects placed in its own task directly, and for anything else sends the
  service a request or a fault and waits ([The construction](#the-construction)). So the root's
  tables need no lock, a request cannot overlap its task's exit, and ending a task, a tree of tasks
  or a budget is a list one thread walks.
* **Handles flow down.** A handle reaches another task only by `erx_cap_pass` from the caller's
  own table into a space the caller created, and nothing passes at a rendezvous. So every holder
  of an object is its creator's task or a task below it, a task's sub-spaces end before it does,
  and what ends with a task has no holder left in a live task. So ending a task's objects with
  it and destroying an object or a budget are safe at any moment: every service use of a handle
  goes through the service's one lookup, every direct use is Fiasco's invocation of a slot the
  root placed, which Fiasco's deletion empties, and every mapping is revoked with its object. Safe
  is not the same as timely: when to delete stays the caller's decision, and the domain library
  still deletes a connection's objects only once each party has unmapped them or ended
  ([design-domains.md](design-domains.md#connections)).
* **One page, one address.** Each page of RAM has one permanent address in the root's pool window.
  Every mapping derives from it, so a mapping can come and go while the page and its contents stay,
  and the root reaches any task's memory without mapping anything.
* **One index per thread.** A task has a fixed table of 128 threads, made with the task. An index
  names a record, a public UTCB, a native UTCB slot and musl's thread identifier.

Each fact about running on Fiasco has one home here. [The call table](#the-call-table) gives every
call's result on Fiasco; where that result differs from erXos's kernel's, its last column names the
row of [Downsides against erXos's kernel](#downsides-against-erxoss-kernel) that says what is lost
and what closes it; and [Security on Fiasco](#security-on-fiasco) cites those rows by name. Paths of
Fiasco's kernel sources are relative to `fiasco/kernel/src/kern/`; nothing here rests on
Fiasco's original `kobject_rpc.h` or `jdb_object.cpp`, which no erXos document or agent reads.

## Contract

The policy:

* Phase 1 brings the system up on a near-stock Fiasco, with the few patches
  this document lists: it boots, its file systems, services and shell work, and
  its user-facing features are built first. Phase 1 does not wait for erXos's
  kernel; the first release, 0.2, ships on Fiasco.
* Fiasco's bugs and gaps are fixed, in the fork or in the backend, unless a fix
  would rebuild erXos's kernel design inside Fiasco.
* What [track F of plan.md](plan.md#track-f-fiasco-improved-to-the-decision)
  does not close is a published downside of running on Fiasco against erXos's
  kernel ([Downsides](#downsides-against-erxoss-kernel)), not a problem to work
  around.
* Whether erXos's own kernel replaces Fiasco is the decision of gate GF in
  [plan.md](plan.md#decision-gates). Until GF decides, Fiasco is the kernel.
* When a design keeps hitting issues, the first step is to read how Fiasco, L4
  and Zircon solved the problem, and a departure from a proven solution that
  has no recorded reason is reversed.
* Nothing ships until it is approved, so every gap is recorded accurately, as a
  downside or a residual.

**Phase 1** in this document includes Phase 1b of [plan.md](plan.md) and 0.2, the first release:
the user-facing system carried further on the same backend, behind the same interface. Its
consumers are:

* the system domain: its release, the console, the host link, the device service, the domain
  library and the domain service;
* **domains** and their connections: the web domain, the session domain, the display domain,
  the network domain, the storage domain and test domains, each a task the domain library builds;
* **programs in sub-spaces**: toybox and recompiled programs, started by a session's port driver
  with their channels, pipe ends and code objects; 0.2 runs littlefs as a NIF in the storage
  domain, not in a sub-space ([design-stopgap.md](design-stopgap.md#release-contract));
* **drivers in their own domains**: virtio-mmio block, net, gpu and input, each held by the
  domain the manifest names.

From them:

* **Every build promises**, for trusted workloads: the results in [the call table](#the-call-table),
  no memory errors, no deadlock, and exact accounting of whatever it reports. The call table is
  the target, and each place the code differs from it is a bug in `TODO.md`.
* **A release on Fiasco promises**, for every domain, trusted or not: isolation of each domain's
  memory and capabilities by Fiasco's address spaces and object spaces, which only the root
  writes, so that isolation rests on Fiasco and on the root's request decoder and placement code
  together, and also, where no IOMMU confines a DMA-capable device, on the domain that drives it
  (FD12) and, unless FD32's entry patch is carried, on the CPU's branch predictors (FD32); rights that only
  shrink; a deleted object gone for every holder at once; memory budgets as hard walls, over user pages, the domain's kernel memory and what the domain can make
  the root hold for it ([Memory and budgets](#memory-and-budgets)); device memory access confined
  by the IOMMU for a device the platform puts behind one, which on 0.2's platforms is none
  ([Devices](#devices)); no one user mapping writable and executable at once in any task but
  `sigma0` and the root (FD8 for two mappings of one page); the results of [the call table](#the-call-table); and the guarantees that rest on
  user-mode code alone, which hold as on erXos's kernel: D1 to D6, D9, D13 and D18 of
  [design-domains.md](design-domains.md) (the funnel, exports, the sender rule, flow control),
  F1 to F3, F5, F9 and F10 of [design-files.md](design-files.md) (grants, roots, narrowing,
  `ro`, handlers), the vault, image hashes and package signatures. Every other family a design
  document numbers (D7, D12, D16, D17, F4, F6 to F8, SH1, P2) is named in the Weakens column of
  the downside rows that weaken it.
* **It does not promise** what [Downsides against erXos's kernel](#downsides-against-erxoss-kernel)
  lists. Each row is a property erXos's kernel has and Fiasco lacks, the consequence a user or an
  app sees, and what closes it. Nothing in this backend rebuilds one of those properties in user
  mode. 0.2 accepts each row but FD33 as a published downside, among them a hostile app's load on
  the root service (FD17) and FD24's reads of what a domain supplies; FD33's acceptance
  [Open decisions](#open-decisions) holds open. FD32 is published unless its entry patch is
  carried, and the null-request bench decides whether it is
  ([The release's Fiasco build](#the-releases-fiasco-build)).
* **It refuses** a call with no consumer in that list with `ERX_ENOTSUP`, which every caller
  checks.
* **It reports as unknown** what only a kernel could know: `unsupported`, or `partial` with its
  reporter and scope, never a made-up number.
* **It contains** only mechanisms with a consumer in that list and stored fields with a reader, in
  L4Re's shapes wherever L4Re has one.
* **It patches Fiasco** only where a release needs a property Fiasco lacks and the patch is small
  and contained: [The release's Fiasco build](#the-releases-fiasco-build) lists them.
* **The interface does not move.** Every caller of `liberx` calls the functions generated from
  `abi/erx_abi.txt`. Where Fiasco answers a call differently from erXos's kernel, the call's row
  says so and names its downside.

[Read in source, never run](#read-in-source-never-run) lists what the first packages must check; a
claim that fails changes this document.

## The construction

### Who holds what

No task but the root holds a capability to a task, a factory, a thread or the scheduler, its own
included, so no task can write any object space or page table, its own included. The root holds
one capability with Fiasco's delete right to every object it creates, so no object dies by
reference count before the root deletes it.

A holder names an object by a handle, an entry of its table in the root ([Handles](#handles)). The
table's fourth column says what the root also places in the holder's own object space. Of the
objects a handle names, only an IRQ object is placed. Every other kind a handle names is the entry
alone: the holder reaches it only through service calls. The semaphores and the request gate are
placed at fixed slots, and no handle names them.

| erXos object | Fiasco object | Created by the root through | Placed in the holder with | The holder's own use |
| --- | --- | --- | --- | --- |
| a doorbell, a device line | an IRQ object (`Irq_sender`) | the owning domain's factory | `L4_CAP_FPAGE_RO`, at the IRQ slot of the holder's entry ([Handles](#handles)): trigger and acknowledgement only, with no special right, so `sys_bind` and `sys_detach` refuse (`irq.cpp:1104-1137`) and the root alone binds | `l4_irq_trigger`; the line's `l4_irq_unmask` |
| a thread's wait object | a semaphore | the thread's domain's factory | the rights `l4_semaphore_up` and `_down` take | umtx, park and the reaper |
| a task's request gate | an IPC gate bound to the root service | the task's domain's factory | the send right, at `L4_BASE_PAGER_CAP` | every service call and fault |
| a thread | a thread | the domain's factory, started by the root through the scheduler with its task's band and its domain's CPU set | nothing: no task holds a thread capability | none |
| a space (a domain's task, a sub-space) | a task | the domain's factory | nothing | none |
| a budget | a factory for the domain's kernel memory, and the root's page record for its user pages | the parent budget's factory | nothing | none |
| a memory object, a mapping | pages of the root's pool, mapped by flexpage | the root's pool; page tables charged to the task's factory | a mapping at the rights the call allows, never writable and executable | loads and stores |
| a device's DMA window | a DMA space | the device domain's factory | nothing: the root maps pages into it and binds the device's stream to it | the device's own accesses |

So the root's records of what sits in each slot, and of what each task maps, are true by
construction: only the root writes them, and the root writes its record with each write. A Fiasco
map into an occupied slot empties it first (`map_util-objs.cpp:110-114`), so no slot holds two
things. The root's one placement function takes its capability as a type whose only members are
the placeable kinds of the table's fourth column (an IRQ object, a semaphore, a gate, a memory
mapping), so a placement of a task, factory, thread or scheduler capability fails to build, and a
test that tries one is kept as a build that must fail. The root's receive buffer register is
zeroed after every `sigma0` call that arms it (`vm.c:396`), and the decoder refuses a request
whose tag carries items, so no request maps anything into the root.

**A step that takes kernel memory finishes or leaves nothing.** Fiasco charges what a placement or a
map needs to the receiving task's quota, which is its domain's factory: a placement may need a new
capability-table page (`obj_space_phys_util.cpp:163,226`), refused as `Insert_err_nomem`
(`map_util-objs.cpp:117-127`), and a memory map a new page-table page (`Mem_space::v_insert`,
`arm/mem_space-arm.cpp:229-233`) and its mapping-database node (`Treemap::insert`, `mapdb.cpp:858`),
refused as `L4_error::Map_failed` (`map_util.cpp:735-760,774-775`). A factory's create fails the same
way, from the factory it is made from. So does a task's added kernel-user memory, which
[vCPU arming](#vcpu-upcalls-on-fiasco) takes: `l4_task_add_ku_mem` charges the area to the task's
quota (`task.cpp:248`), maps it into the task (`:255`), and when either is refused frees the area
itself (`:260-261`) and answers `-L4_err::ENomem` (`:250-251`, `:266`); a request of several areas
keeps those added before the refused one (`task.cpp:880-890`), so the root adds one area per call. A
domain reaches any of these refusals at will, by spending its factory. So every Fiasco call that
charges a task's quota, `l4_task_map`, the `l4_factory_create` family and `l4_task_add_ku_mem`, lives
in one module of the root, `liberx/backend/fiasco/charge.c`, and the `fiasco-charge` chokepoint fails
the build on such a call anywhere else ([The chokepoint](#the-chokepoint)). The module offers the
root's one placement function, its one map function, the only code that maps into a task, its one
factory create and its one kernel-user memory add; the root's own steps at its start use them too,
and a refusal there fails the boot. Each writes the
root's record only once Fiasco has accepted the step, and answers a refusal as `ERX_ENOMEM`, the
domain's own. A refused add arms nothing and leaves no area, since Fiasco has freed it. The call that
met a refusal then undoes what that call created, the maps it
made and the objects it made, and returns `ERX_ENOMEM`; undoing unmaps and deletes, which free and so
take no kernel memory. The two calls that are sequences of independent items keep the items before
the refused one, as their rows say: a pass (FD4) and an image load (FD10). A refused unmap or delete
means the root's records and Fiasco's tables disagree, a defect of the root, which ends the machine
with the reason; nothing else Fiasco refuses does.

One object every thread reaches without a slot is itself: Fiasco resolves the special selector to
the calling thread with the rights `CWS` (`Obj_cap::deref`, `thread_object.cpp:61-75`). Every
operation of the thread object (`thread_object.cpp:204-235`) is therefore open to a thread on
itself, and each harms only its own domain, because each names other objects only through slots of
its own task, which hold nothing but what the root placed:

| Operation | On itself | Release configuration |
| --- | --- | --- |
| `Control` | its pager and exception handler, at slots of its own task, so its faults reach the root or no one; a bind needs a task capability, which it does not hold; the alien flag | `ALIEN` off (`src/Kconfig:427`), so no alien flag |
| `Ex_regs` | its own registers | on |
| `Switch`, `Stats` | a switch to a thread it names, which needs a thread capability it does not hold; its own time | on |
| `Vcpu_control`, `Vcpu_resume` | its vCPU state area; a resume into a task needs that task's capability with the special right | on, for [vCPU upcalls](#vcpu-upcalls-on-fiasco) |
| `Register_del_irq`, `Modify_senders` | an IRQ object of its own slots fired at its deletion; the labels of senders queued on itself | on |
| `Register_doorbell_irq` | `ENOSYS` without `IRQ_DIRECT_INJECT` (`thread_object.cpp:830-833`) | `IRQ_DIRECT_INJECT` off |
| `Pf_tramp_control` | a one-shot page-fault trampoline in its own thread | `PAGEFAULT_TRAMPOLINE` off (`src/Kconfig:452-454`, on by default) |
| the architecture's operations (`arm/thread-arm.cpp:342-351`) | its own `TPIDRURO` | on |

The operation list is the dispatch's; the bodies of `Switch`, `Stats`,
`Register_del_irq`, `Modify_senders` and the architecture's operations are not read,
so their column is unverified and the system-call fuzz campaign's
self-selector cases are what check it.
The worst a thread does with itself is point its faults at an object that does not answer them and
stop, which the root sees when the thread does not arrive at a pause or its space ends. The
release configuration that turns those options off is the exact allowlist of
[The release's Fiasco build](#the-releases-fiasco-build).

### Handles

A handle is an entry of the holder's handle table, which the root keeps, one table per task. An
entry names an object's record, which holds the object's kind, together with the generation that
record had when the entry was made, and it holds the erXos rights this holder has to the object.
A handle's value is laid out as every capability value is (`abi/kernel.txt`, "Capability values
and tables"). Bits 0-23 hold the entry's number, which is its index plus one, so 0 stays
`ERX_CAP_NULL`. Bits 24-63 hold the entry's generation. The root's handle tables and erXos's
kernel's capability tables hand out values of one layout, and the root's one lookup checks what
`erx_cap_read` checks ([design-kernel.md](design-kernel.md#objects-and-capabilities)).

**Two generations, each kept by the one who changes it.** Every close advances the entry's
generation, so the value its holder had names nothing from then on. Every free of an object's
record advances the record's generation, so an entry made for the object that went names nothing
either, until its holder closes it. An entry or a record whose generation reaches the last value
its field holds retires at its free and is never taken again, so no generation wraps back to a
value a holder may still keep. No list of holders is needed to make a value stale: the destroy
never visits the entries that name the object, and the close never visits other tables.

**The one lookup.** Every service call that names a handle reaches its entry through one function
of the core, `liberx/backend/core/handles.c`, in two steps. The entry step checks, in this order,
the entry's number within the table, the entry in use, and the value's generation equal to the
entry's. The object step then checks the record live at the entry's record generation. A failure of
either step is `ERX_ESTALE`, as erXos's kernel answers every value that names no live slot. Then the
lookup checks the record's kind against the kind the call takes, failing with `ERX_ETYPE`, and the
entry's rights against the right the call needs, failing with `ERX_ERIGHTS` ([Rights](#rights)), so
`ERX_ETYPE` means a live object of another kind and nothing else. A call's body gets the record and
nothing else. `erx_cap_close` alone takes the entry step without the object step, since it acts on
the holder's entry, not on the object ([Close and destroy](#handles)). No call reads an entry by
another path, so a closed, stale or forged handle fails every service call, and no call can skip a
check.

**Reserved values and error precedence.** A call that accepts a reserved value tests for it before
the lookup, and its row in [the call table](#the-call-table) says what each answers: `ERX_CAP_SELF`
and `ERX_CAP_SELF_THREAD` name the caller's own space and thread, `ERX_CAP_NULL` is the root's
archive image in `erx_image_map` and `ERX_EINVAL` from a task there, and own-task thread handles,
which are not entries, lie above `caps_max` in the slot bits ([Thread creation](#thread-creation)). A
reserved value a call does not accept goes to the lookup and fails there as any value that names no
entry. Every other failure of the lookup reaches the caller unchanged: no wrapper turns
`ERX_ESTALE` into `ERX_ETYPE` or another status.

**Reuse order.** The root takes a task's free entries first in, first out, as erXos's kernel's
table does. A table grows by a page only when no entry is free, and the new page's entries join the
list in index order. Service uses do not depend on the order, since the generation refuses a closed
handle whatever the entry holds next. The order matters only for direct uses of an IRQ object:
first in, first out reuses a closed entry as late as the table allows, and that delay is all that
stands between a direct ring after close and another object (FD1).

**Close and destroy.** `erx_cap_close` frees an entry that passes the entry step, whether or not its
object still lives: it advances the entry's generation, takes one holder off the record only when
the record's generation still equals the one the entry holds, and appends the entry to the free
list. A record freed by a destroy and taken again for another object so loses no holder to a close
of an entry made for the object that went. For an IRQ entry, the root first
unmaps the holder's slot. The object goes when its record has no holder, no mapping and no keep.
`erx_object_destroy` is the creator's ([Destroying an object](#destroying-an-object)). It deletes the
Fiasco objects through the root's delete right, so Fiasco empties every slot that holds the object's
capability, each holder's IRQ slot included, and then it frees the record. Every entry that names
the object then answers `ERX_ESTALE`, through the lookup for a service call, and through Fiasco's
answer for an empty slot for a direct use, which the stub maps to `ERX_ESTALE`. The entry stays
taken until its holder closes it, so the slot stays empty, and the holder's own close is what frees
both.

**IRQ objects are also placed.** A doorbell or a device line is the one kind of object a holder
invokes itself ([Who holds what](#who-holds-what)). When an entry for an IRQ object is made, by a
create, a duplicate or a pass, the call ends in one placement function of `irq.c`, the only code
that places an IRQ capability in a holder: given the new entry, it places the object's capability in
the holder's object space at the entry's IRQ slot when the entry's rights hold `TRIGGER` or `ACK`,
with the Fiasco rights [Rights](#rights) names, and places nothing otherwise. No call places an IRQ
capability by another path, so an entry whose rights hold neither leaves its holder's slot empty
whichever call made it. The IRQ slot is one constant base, the same in every task, plus the entry's
index. The base is the first slot past the per-thread runs the root keeps in its own space, its
semaphores and its threads; a task uses only the first of those runs. The stub of `erx_irq_trigger`
and `erx_irq_ack` computes the slot from the value's number alone and invokes it, so a ring or an
acknowledgement makes no request to the root. In the root, the window of IRQ slots starts at the
same base, and the root's other slots lie past the end of its window: its service gate and
thread, the watchdog's slot, its slot for each IRQ object, and the slot pool. Every other kind of
object is the entry alone, with no capability in the holder.

A window ends at its base plus the space's `cap_limit`, and it must lie within Fiasco's object
space. **The root's layout is one plan: fixed slots, then a pool.** The root holds a capability with
Fiasco's delete right to every object it creates ([Who holds what](#who-holds-what)), so every
thread, semaphore, gate and task of every domain has a slot in the root's object space, which holds
65,536. The plan lays out, from the backend's constants alone: Fiasco's base capabilities; the
per-thread runs, the same in every task, which in the root hold its own threads and semaphores; the
root's window of 16,384 IRQ slots, the root's handle limit, a declared figure, since what the system
domain holds at once is its policy's and no table determines it; the service gate and thread and
the watchdog's slot; one slot for each IRQ object the machine admits (`ERX_FIASCO_IRQS_MAX`, 256);
and the **slot pool**, every slot left to the end of the object space, in pairs. Under the figures
of this section the pool starts at slot 16,911 and holds 24,312 pairs, its odd last
slot unused. The pool's size is derived, never written down, so no part of the plan can overlap
another. The root's table opens with its limit, and a handle past it is `ERX_ELIMIT`, as in any task.

**What takes pairs.** A thread of a task other than the root takes one pair, for its thread and its
semaphore, and the task's row records the pair's index beside the thread's state, as L4Re's thread
manager takes a thread's capability and its semaphore's from its slot allocator and keeps both in
the thread's descriptor (`l4re-core`, `libpthread/src/manager.cc`, and the allocator,
`l4re/util/include/counting_cap_alloc`; unverified: not read from a pinned source).
A task other than the root takes two pairs, for its gate and its task object in the first and the
semaphore its end ups in the second, the fourth slot unused, and its row records both indices. The
pool's one unit is the pair, so a count of free pairs is also a count of what can be placed: a
take never fails for want of adjacent slots while enough are free, which is what lets the manifest
check share the pool out by counting. A record names a pair by its index plus one, so the zero of
a cleared record names no pair and reaches no slot, and a stale use is Fiasco's refusal; the
numbers fit 16 bits, because the pool holds fewer than 65,535 pairs, and a static assertion says so: the row gains 128 thread pair indices and two task pair
indices, 260 bytes, and stays under half a page, so the task table keeps its two rows a page. The
root's own threads keep their fixed runs, because the root's index 0 is the thread the kernel gave
it and the root's stubs reach its own thread capabilities by index. IRQ objects keep their fixed
slots too: `irq.c`'s table of 256 objects is already the record of each and bounds their number, and
its index names the slot, so a slot from the pool would add a recorded index and a free step and
remove no bound. The direct stubs are not affected either way, since they invoke the holder's IRQ
slot, the base plus the entry's index in the holder's own space, never the root's slot for the
object. Any other object the root comes to hold a capability to takes whole pairs from the pool,
recorded in its own record, and joins the pool's sharing.

**Taking and freeing.** A take scans for the lowest free pair, as the object records are taken
([The one lookup](#handles), `handles.c`). Only the service takes and frees pairs, in the bodies
that create and delete what they hold, and a body runs to its end before the next receive, so the
pool needs no lock, as the task table needs none ([Locks](#locks)). A thread's create takes its
pair before any Fiasco call, so a pool with no free pair is `ERX_ENOMEM` with nothing created, and
its own undo frees the pair. A space's create takes its two pairs with its row, before it makes
any object, and frees them on the same undo. A thread's pair is freed by the deletion of the
thread, in the reaper's request or in step 1 of its task's teardown ([Task exit](#task-exit)),
after Fiasco has deleted both its thread and its semaphore. A task's two pairs are freed when its
row is deleted, after the deletion of the last object in them. A refused deletion ends the machine
([Who holds what](#who-holds-what)), so no pair is ever free while Fiasco still holds an object in
it, and a take never meets an occupied slot.

**The pool is shared out.** The task table holds at most 1,024 rows, and the plan derives that
figure from the row's size and the table's one directory page ([Table sizes](#table-sizes)), so
the pool's spaces never need more than 2,048 pairs, and a static assertion fails the build when
the pool holds fewer than two pairs for every row the task table can hold. Those 2,048 pairs are
held back whole: they are the pool's first, a run of their own, from which only a space's create
takes. The remaining 22,264 pairs are the threads' run, and a domain's share of them is its thread
limit. Both the threads' share
and the task table are machine-wide tables that the manifest check shares out among domains
([Table sizes](#table-sizes)), so a configured domain within its limits never meets the pool's
`ERX_ENOMEM`.

Under `config/fiasco/kernel.defconfig`, which leaves `PHYS_OBJ_SPACE_AVL` off (the option has no
default, `Kconfig:399-407`), Fiasco's object space is a two-level table of `Slots_per_dir *
Caps_per_page` slots (`obj_space_phys_util.cpp:41-42`, `obj_space_types.cpp:195-197`). On AArch64 a
page is 4 KiB (`types/arm/64/types-arch.h:24`), so `Slots_per_dir` is 512 pointers, and an
`Obj::Entry` is 32 bytes: its `Capability` part is one word (`obj_space_types.cpp:48`), and its
`Mapping` part is a list item of two pointers (`cxx/hlist:57`) and one word of bit fields
(`obj_space_types.cpp:88-89`). So `Caps_per_page` is 128, and the space holds 65,536 slots. Both
lookups refuse a directory index past the last (`obj_space_phys_util.cpp:202`, `:223`), so slot
65,535 is the last valid selector and 65,536 the first refused. The directory index is computed in
an `unsigned` from the word-wide selector (`:201`, `:222`), so a selector at or above 2^39 would
alias a low slot unless the invocation path masks it first. Every
selector erXos computes is below 65,536, so the alias reaches nothing erXos places, and a holder's
aliased selector names only its own slots. The figures are read from the in-tree sources (SHA-256
`3b619e13...` for `obj_space_phys_util.cpp`, `3e87dbd1...` for `obj_space_types.cpp`), and a
boot probe checks them on a running kernel: the `native_irq` suite places a capability at slot
65,535 and is refused at 65,536, and checks that a selector 2^39 above an empty slot does not reach
it (`erx_fiasco_test_object_space_probe`, `irq.c`). `erx_space_create` refuses with `ERX_EINVAL` a `cap_limit` whose window would pass
the object space, where erXos's kernel takes any value up to `caps_max` (FD1). A caller that
wants the largest table asks `erx_space_cap_limit_max()`, which answers the largest `cap_limit`
whose window fits, so no code above `liberx` names Fiasco's figure; a session's port driver
makes each program's image with it.

**Verification.** Four parts carry the design, each with the test that proves it and a seeded
fault that test must catch:

* The handle value and the lookup, in `handles.c`, built for the host: the entry's generation, its
  retirement, the first-in-first-out free list, the rights in the entry and the lookup's order.
  `test/host/handles_test.rb` closes a handle and uses the old value after the entry is taken again, expecting
  `ERX_ESTALE`, drives one entry through retirement, and checks the reuse order and every refusal
  of the lookup, closes an entry after its object's destroy and after the record is taken again,
  expecting the new object's holders unchanged, and drives the space-create, image-map and pass
  wrappers with a stale handle, expecting `ERX_ESTALE` from each. Seeded faults: the close not
  advancing the generation, under which the old value names the new object; the generation compared
  after the kind, under which a reused entry of another kind answers `ERX_ETYPE`; a retired entry put
  back on the list; the close decrementing without comparing the record's generation, under which the
  new object loses a holder; and a wrapper mapping a lookup failure to `ERX_ETYPE`.
* IRQ placement and the direct stubs, in `irq.c`, `object.c` and the stubs: the window, the
  placement at create, duplicate and pass, the unmap at close, and the `l4_irq_trigger` and
  `l4_irq_unmask` stubs. The *direct doorbell* and *destroyed handle* cases of
  [The release's cases](#the-releases-cases) prove it, with a pass and a duplicate of an
  IRQ entry into rights that hold neither `TRIGGER` nor `ACK`, each expecting the holder's slot empty, and
  a build of the root's layout plan. Seeded faults: the trigger stub sending a request, under which
  the root's request count moves; the close leaving the holder's slot mapped, under which a ring
  after close reaches the object; the placement function placing unconditionally, under which the
  inspection-only holder rings the object; and the root's window declared so large that the pool
  holds fewer than two pairs for every task row, under which the static assertion fails.
* Rights through create, carve, duplicate and pass, in `object.c`: the creation kind's set, the
  intersection with the mask and the right each call needs. The *rights shrink* and *a creator's
  pass* cases prove it, with a budget carved through an entry that lacks `SPACES`, expecting the new
  entry without `SPACES`. Seeded faults: the pass recording the source's rights unmasked, the map
  body not asking the lookup for `WRITE`, and a carve recording its creation kind's whole set.
* The slot pool: its take and free, built for the host in `liberx/backend/core`, and the root's
  uses of it, in `service.c` and `service_task.c`: the pair a thread's create takes and its reap and
  its task's teardown free, the two pairs a space's create takes and its row's deletion frees, and
  each create's undo. A host test takes pairs until the pool is exhausted, expecting distinct pairs
  lowest first and then a refusal, frees one and expects it taken next, and frees the last pair and
  expects it taken again. Seeded faults: a take that does not mark its pair, under which two takes
  answer the same pair; and a scan that stops one pair short, under which the exhausting run ends a
  pair early (`test/host/slot_pool_test.rb`). The `native_task` suite's `pool_rounds` case runs, in a
  test task, more thread creates, starts and exits than the pool holds pairs, each expecting `ERX_OK`;
  its `root_stops` case stops a space whose threads are live and joins it, and every case of the
  suite expects through the test hooks the pool's free count back where it started and every free
  pair's slots empty. Seeded faults: the reap not freeing the thread's pair,
  under which a create in the loop answers `ERX_ENOMEM`; and a row's deletion not freeing the task's
  pairs, under which the free count ends two pairs a space short. The manifest check's clause 9
  case refuses a manifest whose thread limits pass the threads' share of the pool; seeded fault: the
  clause leaving the pool out, under which that manifest passes.

### Rights

Each entry records the holder's erXos rights to its object. A create gives its caller the default
set of its creation kind in `abi/kernel.txt`, through the generated `erx_rights_create`, so two
ways of making a memory object give the rights their kinds name and no more. A carve, a budget from
a budget or a slice from the boot image, records its creation kind's set intersected with the
parent entry's rights and `DESTROY`, as on erXos's kernel
([design-kernel.md](design-kernel.md#rights), K2), so a budget carved through an entry without
`SPACES` holds no `SPACES`, and no right is regained by creating. A duplicate or a pass
intersects the source entry's rights with the call's mask and records the result in the new entry.
A pass also drops `DESTROY`, since only an object's creator destroys it here. So rights only shrink.
The one lookup checks the right each call needs against the entry ([Handles](#handles)), so every
service use enforces the rights, whatever the holder's `liberx` asks, and a pass reports in each
item's descriptor exactly the rights its new entry records.

The direct uses are an IRQ object's ring and acknowledgement. The root places an IRQ object's
capability with Fiasco's read right alone, `L4_CAP_FPAGE_RO`, and never with the special or the
delete right, whatever the entry's rights, and it places none for an entry whose rights hold
neither `TRIGGER` nor `ACK`. Fiasco's bind and detach need the special right (`Irq_sender::sys_bind`,
`irq.cpp:1104-1137`), so no holder binds through its capability, and `BIND` is checked by the
lookup of the service's bind. Fiasco's trigger and acknowledgement check no right
(`Irq_sender::kinvoke` and `dispatch_irq_proto`, `irq.cpp:327-339`, `:1150-1180`). So every holder
with a capability can both ring and acknowledge, where erXos's pass set for the type gives
`trigger` without `ack` (`abi/kernel.txt:512-514`), a difference FD13 records. A ringer's
acknowledgement of a peer's doorbell does nothing, since a software object has no line to mask
([Interrupts and readiness](#interrupts-and-readiness)), and a device line is placed only in the
domain that holds its device.

Every pass is a creator's into a space the creator made. Any task passes into a space it created,
as the domain library in the root installs a domain and a session installs a program
([The call table](#the-call-table)). Pass sets do not bind that case on erXos's kernel either
([Passing a handle](#passing-a-handle)), so the creator's mask is what narrows it.

### Destroying an object

`erx_object_destroy` is the root's delete through its delete right, after which Fiasco's object
deletion removes the capability from every holder at once; a memory object's destroy unmaps its
pages from every space through Fiasco's mapping database. Ending a domain deletes every object the
root's records charge to its budget, and then its factory, in the root's one list walk
([Deletion](#deletion)).

### Memory and budgets

Each domain budget is a wall at its guarantee, in three parts, one Fiasco holds and two the root
holds:

* **Kernel memory** is a Fiasco factory carved from its parent's at the budget's creation, with the
  kernel-memory figure of the domain's manifest row. Fiasco charges the child's whole limit to the
  parent at creation (`factory.cpp:81-86`), so the limits are a hard partition, and charges every
  task's page tables, capability tables and kernel-user pages to the factory the task was created
  from (`space.cpp:69-99`, `obj_space_phys_util.cpp:163,226`). When a domain's factory is spent,
  the root's next creation or map on its behalf fails and the call answers `ERX_ENOMEM`. A budget
  carved below a domain's (a connection's child budget, a program's budget) has no row of its own:
  its factory takes the share of its parent's kernel memory that its guarantee is of its parent's
  guarantee, so every budget keeps its domain's ratio of kernel memory to pages, and a carve that
  leaves the parent's factory short is `ERX_ENOMEM`.
* **User pages** come only from the root's pool, since the root alone maps memory, and are charged
  to the budget's page record. Every budget is a wall: its record holds one number, its **wall**,
  which is both its guarantee and its cap, so a cap that differs from the guarantee cannot be
  recorded. `erx_budget_create` of an elastic kind is `ERX_ENOTSUP` (FD25), and of a wall whose cap
  is not its guarantee `ERX_EINVAL`, as erXos's kernel requires of a wall. Each record also counts
  `used`, the pool pages charged to it, and `carved`, the walls of the budgets carved from it, and
  one invariant holds for each: **`used + carved <= wall`**. Every change to either count checks it
  in the request that makes the change, inside the call's whole-plan check
  (`erx_backend_vm_plan`), before any page moves: a call that takes a page, a commit or an object's
  creation, charges the budget that owns the memory object, which the object's record names; a carve
  adds the child's wall to its parent's `carved`; a resize moves its parent's `carved` by the
  difference, and its own wall may not fall below its own `used + carved`; and a budget's
  destruction takes its wall off its parent's `carved`. A refusal is `ERX_ENOMEM`, `ERX_EINVAL` for a
  resize below what the budget holds, and changes nothing. A page given back refunds the budget that
  was charged. Shared backing is charged once, to the object's budget, never per mapping. So a
  parent that has carved part of its wall spends only the rest, and a child grows only out of its
  parent's unspent wall.
  The root's budget has no record. Its account is two counters kept beside the pool's count, under
  the same invariant with the pool's page total as its wall: the root's own pages (its tables, the
  time page, the image slices it keeps) and the walls carved from the root's budget. So a carve from
  the root's budget, and every page the root takes for itself, is checked as any other charge.
  The tests: a budget of wall 100 carves 80 and commits 20 pages, the 21st `ERX_ENOMEM`; a create
  asking a guarantee of zero and a large cap `ERX_EINVAL`; a resize that grows a child past its
  parent's unspent wall `ERX_ENOMEM`; a destroy whose wall the parent can carve again; and a carve
  from the root's budget past the pool's unspent pages `ERX_ENOMEM`. Seeded fault: the charge
  checking `used` alone against the wall, under which the first test's parent commits all 100.
* **What the root holds for the domain.** Some of a domain's cost lands on the root, not on the
  domain's factory: the root's capability to each of the domain's objects grows the root's own
  capability table, which Fiasco charges to the root's quota (`obj_space_phys_util.cpp:163,226`);
  a map the root makes into one of the domain's tasks takes its mapping-database node from the
  receiving task's quota, the domain's factory (`mapdb.cpp:858`; `Mapdb::insert`, `mapdb.cpp:1109-1110`,
  "takes quota from `space`"), so the domain's kernel-memory figure covers it, and only a map smaller
  than the root's own mapping of the page needs a new submap node, which the root, as the mapping's
  parent, pays for (`mapdb.cpp:880-886`); every held exception takes a reply slot of the
  root's ([Threads, bands and stops](#threads-bands-and-stops)); and every object takes a record
  and a page-index label of the root's tables. So the domain's row bounds these too: besides its
  thread limit it names an object limit and a mapping limit, the root's cost per thread, object and
  mapping is a constant of the backend (for a mapping, its record and at most one submap node, never
  its leaf node, which the domain's factory pays), and the domain service admits a domain only when the root's
  own kernel memory and tables have that cost left, as a budget is carved from what its parent has
  left. A create or map past a limit answers `ERX_ELIMIT`, and no table of the root is shared
  between domains, so a domain that spends its own share fails alone. Its sub-spaces and the
  budgets carved below it count in its share.

### Threads, bands and stops

The root creates every thread, so it knows every thread of every task. Each task's row records its band
and names its domain's row, which holds the domain's CPU set and slice, from its grant ([Bands](#bands)); the root starts each thread at its task's band's base,
with the domain's slice as its quantum, and within
its domain's CPU set through `l4_scheduler_run_thread`, which takes the priority, the quantum and the CPU set
(`scheduler.cpp:63-110`) and checks nothing about the caller beyond its holding the scheduler; a thread that set its own urgency it runs at the band's ceiling from then on ([Urgency](#urgency)). Since
Fiasco picks a CPU from whatever mask it is given and knows no domain (`scheduler.cpp:96-103`), the
domain's CPU set is the root's ceiling, applied in one place: every mask the root hands Fiasco for a
thread is the thread's requested mask, or every CPU when none was requested, intersected with its
domain's CPU set and the online CPUs. The narrowing is one function, and its result is a
single-member struct that only it returns and that the root's one call of `l4_scheduler_run_thread`
takes, so a mask that skipped the narrowing fails to build, as a placement of a task capability
does ([Who holds what](#who-holds-what)), and a test that tries one is kept as a build that must
fail. The domain service refuses to admit a domain whose CPU set holds no online CPU, with a
diagnostic naming the domain and its set, so the narrowed mask of a thread with none requested is
never empty. So no start or affinity change places a thread outside its domain's set, and a thread
runs on the root service's CPU only when its domain's set holds that CPU. A group's
configured CPU set is recorded narrowed to the domain's set, as erXos's kernel narrows a group's set
down the tree, and places no thread (FD15). The root counts a domain's threads across its tasks, its sub-spaces' included,
against the domain's thread limit in its domain row, and a create past it answers `ERX_ELIMIT`. This is L4Re's own shape: ned gives each program a scheduler proxy that
restricts its threads to a CPU set and to a range of priorities, `prio_offset` to `prio_limit`
([L4Re's ned documentation](https://l4re.org/doc/l4re_servers_ned.html), "Control scheduling",
fetched 2026-11-15, SHA-256 `57b4c33485cf6a8ea404fd4471d4250eb62c2f57268cd5b4f7eb7e5a8eacb06f`).
The scheduler is in [its own section](#the-scheduler-on-fiasco).

The root sets every thread's pager and exception handler to the task's gate. A thread may repoint
its own through the self selector, but only at slots of its own task, so its faults reach the root
or no one, and a thread whose faults reach no one stops itself alone.

**The pause.** A whole-space pause, which `fork`'s copy and job control need
([design-programs.md](design-programs.md)), is the root holding every thread of the space at its
gate, as a Fiasco task's manager acts on its threads, with no change to Fiasco. Its one rule is
that the root never waits for a thread:

* The pause request is not answered at once. The root keeps the requester's reply in a reply slot
  and goes on serving.
* For each thread of the space that its records do not already show held (a thread whose fault
  the root holds is held already, and counts from that record), the root runs `ex_regs` with
  `Exr_cancel` and `Exr_trigger_exception` (`thread_object.cpp:639-660`). Without `Exr_cancel`
  the trigger does nothing to a thread already in an exception, and nothing until a thread blocked
  in an IPC leaves the kernel, so an ERTS scheduler parked on its semaphore would never arrive.
  With it, a blocked wait or call ends with Fiasco's cancel status, and `liberx`'s wait and call
  stubs retry a cancelled wait or call after the thread is resumed, so no caller sees it.
* Each thread's exception message arrives at the task's gate and the root keeps its reply in a
  reply slot, answering none until the resume. The root counts arrivals against its own pause
  record, which lists the threads it triggered, never against the message's words. Fiasco tells
  the root which gate a message came through, not which thread sent it, so a thread of the space
  can send a message shaped like an exception and be counted in place of another thread; the
  pause can then return while a thread of that space still runs, which harms only that space's
  own copy or job control (FD21).
* When the count is complete, the root answers the requester. If it is not complete within the
  pause's deadline, a constant of the backend (100 ms until the pause's case prices it), as when a
  thread repointed its exception handler at a slot that does not answer, the root ends the space
  as `erx_space_stop` does, and the requester gets `ERX_EDEAD`.
* The resume answers every held reply, which returns each thread to the state its exception
  froze.

Holding many exceptions at once needs Fiasco's explicit reply capabilities (`EXPLICIT_REPLY_CAPS`,
`src/Kconfig:441-450`, on by default), a reply space per task charged to that task's quota
(`reply_space.cpp`). The root's reply slots are one per thread index of each paused task and one per
pending requester, so a domain's pauses hold at most its thread limit of them, inside its share of
the root ([Memory and budgets](#memory-and-budgets)). Which reply slot Fiasco fills for an
exception, and that a cancelled IPC returns to the stub with a status it can retry, are read from
the Kconfig help and `ex_regs` only and are unverified until the pause's case runs.

### Devices

Fiasco carries DMA spaces behind an IOMMU (`dmar_space.cpp`, the QEMU `virt` binding in
`arm/bsp/virt/iommu-arm-smmu-v3-virt.cpp`). For a device behind one, the root creates a DMA space
in the device domain's factory, maps the device's buffers into it at the addresses
`erx_mem_dma_addr` reports, and binds the device's stream to it; the device reaches nothing else.
On 0.2's platforms no device is behind one: QEMU `virt`'s IOMMU serves only PCIe functions on the
root bus, which the harness does not start for the production image, and never a virtio-mmio
device, and the Raspberry Pi 4 has no IOMMU at all
([design-platforms.md](design-platforms.md), the DMA table). So every DMA-capable device of 0.2 is
unconfined, and on the Pi 4 a compromise of any driver that masters DMA is a compromise of the
machine (FD12). An unconfined device runs as on erXos's kernel, a property of the hardware, not of
the kernel, and the manifest check refuses such a device to any domain but the one the manifest
gives it alone.

MSIs on QEMU `virt` come through its MSI frame, since HVF's in-kernel interrupt controller has no
MSI translation service and the harness gives TCG the same frame
([design-platforms.md](design-platforms.md), "One interrupt path under both accelerators"). The
frame turns the value a device writes into the
line it raises, so an MSI is a line of the frame's range that the root binds through Fiasco's
interrupt controller like any other, and every device that can write the frame shares one trust
boundary for interrupts. Fiasco's own MSI manager (`irq_mgr_msi.cpp`), which the `virt` binding
sets up over the interrupt controller's MSI translation service
(`arm/bsp/virt/pic-arm-virt.cpp:39-47`), is not used.

### What the root still serves

Creation, placement, passing, closing and deletion; every map, protection change and fault of
memory; budgets and groups as records; thread creation, start, affinity and stops; the boot
handoff, the log, entropy, the time page and the watchdog; and the policy of the system domain
above them. As in L4Re, where `moe` serves memory and faults while programs invoke kernel objects
themselves, a domain's steady-state traffic does not reach the root: rings and acknowledgements of
its IRQ objects, which go to the capabilities at its IRQ slots ([Handles](#handles)); its waits, on
its own semaphores; and loads and stores to its memory. Its setup does reach the root.

## The call table

Every consumer kept in Phase 1 has a row, and `ERX_ENOTSUP` answers everything else. This one table
gives every call's result on Fiasco, its refusals included, on a development build and a release
alike; it is the one place results are written, and the downside rows and other sections cite it.
It is the target, and code that differs from it is a bug in `TODO.md`. Its last column names the rows of [Downsides against erXos's kernel](#downsides-against-erxoss-kernel)
where the result differs from erXos's kernel's, and a row whose last column says none gives erXos's
kernel's result. The parity review between the backends works from it: a difference that neither a row nor its downside
names is a bug in one backend. A call that names a space takes `ERX_CAP_SELF` or a space handle, and
a task holds a space handle only for a space it created, since no space handle passes; so "a space
the caller created" is checked by the handle alone. "Service" and "local" say where the body runs.
The hosted backend carries the rows between tasks where cheap and answers `ERX_ENOTSUP` elsewhere
([The hosted backend](#the-hosted-backend)). One function-API test set, `test/guest/function_api`,
runs each case on every backend that carries its row and seeds Track K's conformance roster.
`erx_cap_pass` takes any task's call in its creator's case, as the domain library in the root
installs a domain and a session installs a program. `erx_space_create`, `erx_image_map`,
`erx_budget_create`, `erx_group_create` and a doorbell's `erx_irq_create` take any task's call, as a
session builds a program's spaces, budget, group and doorbells with them. Every other row takes its
callers as it says.

| erXos call | Consumer | Body | Result and refusals on Fiasco | [Downside](#downsides-against-erxoss-kernel) |
| --- | --- | --- | --- | --- |
| `erx_vm_reserve`, `_commit`, `_decommit`, `_release`, `erx_space_protect` | musl `malloc`, ERTS allocators, stacks; the domain library and a session's port driver reserving in a space they created | service: [Budgets](#budgets-and-the-ownership-of-pages), over the caller's space or one it created; a task's commits are charged to the budget of the object they fill ([Memory and budgets](#memory-and-budgets)) | correct contents; `ERX_ENOMEM` from the pool, past that budget's cap, or with no free range; write and execute together `ERX_EINVAL`; a touch of a decommitted page is a fault; a release over a whole mapping removes it, and a commit or decommit that meets a mapping, or a release that cuts one, `ERX_EINVAL`; a protect that meets a mapping `ERX_ENOTSUP`; no call replaces a mapping in place, so a caller swapping one releases it, reserves the range again and maps the new object, the range unmapped between the steps; a map Fiasco refuses for kernel memory `ERX_ENOMEM`, the call undone ([The range table](#the-range-table)) | FD7, FD8, FD34 |
| `erx_mem_create`, `erx_vm_map` | a connection's two sides and its pixel area, which both parties map, a domain's boot information page and crash area (the domain library); a channel's two sides, a data area, the exec record of a program `erx_exec` loads and a pipe's rings and lock page (a session); a driver's buffers; BeamAsm's JIT objects; the time page, a group's areas | service: pool pages recorded as an object, all committed and zeroed at creation, charged to the budget named; each map is `l4_task_map` from the window into the space named, at addresses reserved there and neither committed nor mapped, with a mapping record ([Shared objects](#shared-objects-and-the-jit-alias)). Any object a task holds a handle to maps, whoever created it. `ERX_MEM_JIT` only from a task made with `ERX_SPACE_JIT`, else `ERX_ERIGHTS` | any number of mappings, into any task the caller may name; an address, size or offset off a page boundary, or a size of 0, `ERX_EINVAL`; offset plus size past the object's end, computed with checked arithmetic so an overflow is past it too, `ERX_ERANGE`, refused before any page is mapped; addresses already committed or mapped, or outside a reservation of the target, `ERX_EINVAL`; a write right over a sealed or code object, or a right the caller's entry for the handle lacks, `ERX_ERIGHTS`, so a connection's party, passed its peer's side without write, maps it read-only; a create past the domain's object limit, or a map past its mapping limit, `ERX_ELIMIT`; no pages `ERX_ENOMEM`; `erx_mem_grow` `ERX_ENOTSUP`. An object goes at the first of: its destroy, its budget's destroy, the end of the task that created it, or the moment its last handle and its last mapping are both gone | FD5, FD9 |
| `erx_image_slice`, `erx_image_map` | the domain library: a domain's release slice and runtime image; a session's port driver: a program command's slices, the loader `erx_exec`; the test-task launcher | service: a slice is a record of whole entries of the archive, charged to the budget named; `erx_image_map` loads an entry in either of two forms and returns the entry point. Its `image` is a slice the caller holds and its `entry` an index into the slice's run of entries, `ERX_ERANGE` past it; the root alone may name `ERX_CAP_NULL` as the image, and then `entry` is the archive's own index, as the domain library maps a runtime image entry, which no slice holds. Its target is a space the caller created. A handle of another kind is `ERX_ETYPE`, as is a memory object that is no slice; a task's `ERX_CAP_NULL` is `ERX_EINVAL`, and so is an index past the archive on the root's path. An image entry (a domain's runtime), planned by `erx_image_plan`, maps each read-only and read-execute segment from the archive's own pages, which the pack tool stores whole from a page boundary, through the service's slice of that entry: one slice per image entry, made at the entry's first map once the entry's file has a good verdict, the only slice that entry ever has (`erx_image_slice` refuses a run holding an image entry with `ERX_ERANGE`), with its pages cleaned and invalidated, charged to the root's budget, named by no handle and so ended by no destroy, and kept until the machine ends. The verdicts are the root's, kept as erXos's kernel keeps its own ([Verdicts](design-kernel.md#checking-a-file)), one byte per archive entry, unchecked, good or refused, which moves only to final (`liberx/backend/fiasco/verdict.c`). What differs is who hashes: the root's `erx_image_map` of an image entry runs `erx_pack_file_check` over the entry's file in the calling thread before its request while the entry is unchecked, and the service only reads the verdict, so its one thread, which serves every task's calls and the root's, never hashes a runtime image, a run of megabytes; a task's `erx_release_entry` check of a file is the service's and goes through the same verdicts, so neither path hashes a file the other has checked. The boot's checks of the root's own image and of the manifest, and the root's `erx_release_check` of its release, keep no verdict here. The archive is mapped into the root read and execute and never write, so the bytes a slice maps are the bytes the check read. Every space that runs the entry so maps the same pages, read-only or read-execute, which none can write, as on erXos's kernel; they are the archive's, so no budget and not the root pool pays for them, and a domain is charged only its writable segments. Those are copied through the window into pool pages of the target space and mapped read-write, each space its own. A file entry holding an ELF executable (the test-task launcher's programs), planned by `erx_elf_plan`, keeps its file's offsets, so every segment is copied that way, code cleaned and invalidated and then made read-execute. `erx_image_map` refuses an image not linked at fixed addresses with `ERX_EINVAL`, as nothing here relocates; every refusal of the entry's plan is `ERX_EINVAL`, without the kernel's `ERX_ENOTSUP` for another ABI version; an image entry whose hash check fails is `ERX_ECORRUPT`, and the service refuses an image entry before it plans it, when the entry has no good verdict with `ERX_ECORRUPT` and when its slice cannot be made with that slice's refusal; a range in use is `ERX_EINVAL`, as `erx_vm_map` answers, where the kernel answers `ERX_EEXIST`; and a load that fails partway leaves the segments before it mapped until the space is destroyed; `erx_vm_map` of a slice maps the archive's own pages read-only with `l4_task_map` from the root, where `sigma0` mapped them one to one. `erx_image_map` from any task, from a slice it holds into a space it created | a range off entry boundaries, or a file of the system release asked by a task other than the root, `ERX_ERANGE`; a write right on a slice `ERX_ERIGHTS`; a slice whose entries would pass the page index's slice entries ([The range table](#the-range-table)) `ERX_ENOMEM`, before any entry is added; destroying a slice revokes its mappings, as any memory object's destroy does, so a second slice over the same entries loses its mappings too (inferred from `vm.c:599-613`, untested) | FD10 |
| `erx_mem_create_paged`, `erx_mem_supply`, `erx_mem_seal` | code objects, which the domain service makes for a session's command server (`erx_dom_code_object`); data objects, which a session's filler makes | service, from 1b-B, whose sessions are the first consumer, and `ERX_ENOTSUP` in 1b-A: calls 49, 50 and 51 of `fiasco_call`, a create taking `erx_fiasco_mem_create_request` with `ERX_MEM_CODE`, bit 1 of `mem_flags` beside `jit`, its one flag, a supply `erx_fiasco_mem_copy_request` with the paged object as `dst`, 64 pages a request as a copy goes, and a seal `erx_fiasco_cap_request`; a paged object is a shared object with a sealed flag, its pages zero at creation; a supply copies from the source object's window pages into the target's, as `erx_mem_copy` does; a seal sets the flag, and every map and supply reads it, since the service performs every one | a map of an unsealed paged object `ERX_EBUSY`; a supply into a sealed one, and a write right in a map of one, `ERX_ERIGHTS`; a supply whose offset plus length passes the target's end, or whose source offset plus length passes the source's, each computed with checked arithmetic, `ERX_ERANGE`, before any byte moves; a source that is physical memory or a JIT object `ERX_ETYPE`; a supply writes every page of its range, supplied before or not; `ERX_MEM_CODE` from a task other than the root `ERX_ERIGHTS`, since the code right is the system domain's, and any other flag `ERX_EINVAL`; a seal always succeeds, since an unsealed object has no mapping and so no writer, and of an object `erx_mem_create` made is `ERX_ENOTSUP`, of device memory, a slice, a child or a JIT object `ERX_ETYPE`; an `erx_mem_copy` into a paged object `ERX_ERIGHTS`, so the supply is its one writer; `erx_mem_dirty`, `erx_mem_own` `ERX_ENOTSUP` | FD9 |
| `erx_mem_child` | `erx_exec`'s writable segments of a loaded executable ([design-programs.md](design-programs.md#what-a-program-can-start), "An executable file") | service, an eager copy: call 52 of `fiasco_call`, taking `erx_fiasco_mem_child_request`, makes the child, a new memory object of the range's size charged to the budget named, which maps read and write and never to run; the stub then fills it with `erx_mem_copy` of the parent's range, 64 pages a request, and closes it if the copy fails, so the child holds the parent's bytes as they were and every write stays its own | a parent that is not immutable, a slice or a sealed paged object, `ERX_ETYPE`, a child included; a size of 0, or a size or offset off a page, `ERX_EINVAL`; a range past the parent's end, by checked arithmetic, `ERX_ERANGE`; a map of the child to run `ERX_ERIGHTS`; the copy's refusals | pages copied at first touch and shared until then; a child dies with its parent and carries no `CHILD` |
| `erx_mem_copy` | the domain service reading a crash area; a server reading a client's memory | service: copies between the two objects' window pages, at most 64 pages a request, so the stub loops | either object gone `ERX_ESTALE`, never a fault; an offset plus length past either object, computed with checked arithmetic, `ERX_ERANGE`, before any byte moves; physical memory or a JIT object `ERX_ETYPE`; a sealed destination, or a slice, whose pages are the archive's, `ERX_ERIGHTS` | FD11 |
| cache maintenance, the code barrier | BeamAsm | local: asmjit's and ERTS's sequences unchanged ([design-arch-aarch64.md](design-arch-aarch64.md)) | correct | none |
| `erx_mem_create_physical` | `erx_device`: the console UART (M3) and the host link's; through a give in its holder's creation, each device's register window for its holder, and the root's own give at boot for each such device the system domain holds ([Device records](#device-records)) | service, from the root only: `l4sigma0_map_iomem` into a fresh range of the root's device window, over the base and size its caller reads from the manifest's device entry; each map is then `l4_task_map` from there into the space named, as for a shared object; for the console UART also [the handoff](#the-console) | RAM, which `sigma0` keeps, `ERX_ERANGE`; execute `ERX_ERIGHTS`; no free range of the device window that holds it `ERX_ENOMEM`, asked before `sigma0`; a create from a task other than the root `ERX_ENOTSUP`, since the domain library makes every device's objects and passes them | FD13 |
| `erx_mem_create_contiguous`, `erx_mem_create_contiguous_in`, `erx_mem_dma_addr` | a device's one memory for the boot, which the device NIF carves its rings and buffers from, in whichever domain holds the device | service: a create from the root only, first fit from the [contiguous pool](#the-pool), aligned to a page, which no cache-writeback granule exceeds, at most `ERX_MEM_CONTIGUOUS_MAX` (16 MiB), wholly inside the DMA range the device tree gives the device it is made for ([design-device-tree.md](design-device-tree.md#facts-into-records)), cached, zeroed, and never given back; the domain library passes it to the device's holder, and the root makes one at boot for each device of a kind the system domain holds ([Device records](#device-records)). `dma_addr`, from any task holding the object, is physical address plus offset plus that device's `dma_bus - dma_cpu`, or, for a device the root confines ([Devices](#devices)), the address its DMA space maps the object at; no device on QEMU `virt` as the harness starts it or on the Pi 4 is behind an IOMMU ([design-device-dma.md](design-device-dma.md#device-addresses-and-reach)) | no such run `ERX_ENOMEM`; `dma_addr` of another kind of object `ERX_ETYPE`, past the object `ERX_ERANGE`; execute `ERX_ERIGHTS`; a create from a task other than the root `ERX_ENOTSUP`; unconfined unless the root confines the device; `erx_dma_map`, windows `ERX_ENOTSUP` | FD12, FD13 |
| `erx_irq_create`, `erx_irq_bind`, `erx_irq_ack`, `erx_irq_trigger` | device lines, in whichever domain holds the device; a connection's bells; a channel's and a pipe end's doorbells; ERTS's wakes | service: `l4_factory_create_irq`, from any task for a doorbell (`ERX_IRQ_SOFT`); for a line, from the root only, `l4_icu_bind`; for an MSI (`ERX_IRQ_MSI`), from the root only, a free line of the range the platform's MSI frame serves, bound the same way, answering, beside the object, its `erx_msi_message`: the doorbell address, the frame's base plus `0x40`, and the data, the line's interrupt id ([design-pcie.md](design-pcie.md#the-msi-frame-on-fiasco)); a bind to a group, from the root into any group it holds and from another task holding the object only into the group that task is the home of or a group it created, as a session binds a program's doorbell into the program's group ([design-programs.md](design-programs.md#the-channel)), gives the object a free entry of the group, records the label and runs `l4_rcv_ep_bind_thread(irq, dispatcher, entry)` on the group's home task's dispatcher, once both exist, a bind again to the same group moves the label, and an unbind runs `l4_irq_detach` ([Interrupts and readiness](#interrupts-and-readiness)); a bind to a worker thread of the caller's own task gives the object a free entry of the task's label page and runs `l4_rcv_ep_bind_thread(irq, thread, entry)`, so its deliveries reach that thread's `erx_ipc_wait` ([Urgency](#urgency), "A bind to a thread"); the object's destroy runs `l4_irq_detach`; an ack and a trigger are the holder's own `l4_irq_unmask` and `l4_irq_trigger` on the capability the root placed at the IRQ slot the handle's number fixes, without Fiasco's special right, so only the root binds or detaches, and they make no request ([Handles](#handles)); a bind checks `BIND` in the caller's entry; a delivery goes from Fiasco to the dispatcher, or to the thread the object is bound to, directly | each label once, the line masked until acked; `erx_irq_route` `ERX_ENOTSUP`; a target that is neither a group the caller holds nor a thread `ERX_ETYPE`, and so is an executor, whose group's ready list is its wait; a thread of another task `ERX_ENOTSUP`; in a task of the root or driver band, a bind to a thread of a doorbell another task holds `ERX_ENOTSUP`, and so is a pass of a doorbell bound to a thread ([Urgency](#urgency), "What reaches the urgent level"); a delivery to a thread armed for [vCPU upcalls](#vcpu-upcalls-on-fiasco) is an upcall; a bind of a bound object to another group `ERX_ENOTSUP`; from a task other than the root, a bind to a group it neither created nor is the home of, or a bind or an unbind of an object bound to such a group, `ERX_ETYPE`; a group's 65th bound object `ERX_ELIMIT`; a create past the domain's object limit `ERX_ELIMIT`; a line's second object `ERX_EBUSY`; a line or an MSI created from a task other than the root `ERX_ENOTSUP`; an MSI with no free line of the frame `ERX_ELIMIT`; the resource ignored | FD13, FD14, FD23 |
| `erx_group_create`, `_configure`, `_info`, `_take_ready` | the adapter's five changes (M3); the domain library's group and sub-space group for each domain; a session's group for each program | service for `create`, from any task under a budget it holds or its own, and for `configure`, local for `info` in the root, on the root's own group only (`ERX_EINVAL` on another group there, `ERX_ENOTSUP` in a task), and local for `take_ready` in the group's home task: [Budgets and groups as records](#budgets-and-groups-as-records), [Interrupts and readiness](#interrupts-and-readiness). `configure` keeps only the CPU set of the grant in the caller's UTCB, narrowed to the group's domain's CPU set ([Threads, bands and stops](#threads-bands-and-stops)), a set with no CPU of it `ERX_EINVAL`, and `info` writes an `erx_info_group` there, with that set as `cpuset` and the root's status page's `parked` and `ready`, and only their bits of `reported` set, `cpuset`'s only once a set was configured ([Reporting kernel objects](#reporting-kernel-objects)) | correct readiness; everything else `unsupported`; no guarantee, quota or throttling; budget and parent recorded, and a group goes with its budget; every thread of a group runs in one task, its home, so a thread created in another task `ERX_ENOTSUP`; a task's second home group `ERX_ENOTSUP` | FD6, FD14, FD15 |
| `erx_park`, `erx_executor_wake`, `erx_yield` | ERTS's schedulers (M3) | local: [The park protocol](#the-park-protocol); `l4_thread_yield` | no lost wake; a worker `ERX_ETYPE` | FD16 |
| a blocking call from an executor | ERTS's executors | local: `liberx`'s stub | `ERX_EWOULDBLOCK`, which the domain's own code can bypass | FD18 |
| `erx_thread_set_urgency` | the ERTS adapter, once, for a runtime's urgent scheduler | service: the root records the level in the thread's row and runs the thread at it with `l4_scheduler_run_thread` ([Urgency](#urgency), "The level") | on the caller's own thread: its band's ceiling for an urgency above its group's base, its band's base otherwise, kept whatever affinity change follows, and no change in a band whose ceiling is its base; above `ERX_URGENCY_MAX` `ERX_EINVAL`; on any other thread `ERX_ENOTSUP`; no refresh of other threads and no clamp along a group path | FD15, FD16 |
| `erx_umtx_wait`, `erx_umtx_wake` | musl's futexes | local: [The umtx table](#the-umtx-table) | correct within a task | FD22 |
| `erx_thread_create`, `_start`, `_exit`, `_set_affinity` | `pthread_create`, ERTS's threads, `libc-test` | [Thread creation](#thread-creation), [Deletion](#deletion); affinity is `l4_scheduler_run_thread` | no free index `ERX_ENOMEM`; a create past the domain's thread limit `ERX_ELIMIT`; an empty mask, or one naming no online CPU of the thread's domain's CPU set, `ERX_EINVAL`; affinity runs the thread on one CPU of the mask within that set, its own if the mask holds it, and a mask naming CPUs outside the set is narrowed to it, as erXos's kernel narrows a thread's affinity to its group's CPUs; a thread with no mask runs on its domain's set; in a space the caller created, only that space's first thread, so a second `ERX_ENOTSUP`; a handle naming another task's thread names one only for the root or that task's creator, else `ERX_EINVAL`; a start of a started thread, a faulted one included, `ERX_EINVAL`; a thread's own-task handle, and a creator's handle to the first thread of a space it created, names no thread once it is reaped, and the index's next thread after that; an affinity change keeps the thread's urgency ([Urgency](#urgency)) and refills its quantum ([Scheduling](#scheduling)); `erx_thread_stop`, `_read`, `_write` `ERX_ENOTSUP` | FD2, FD14, FD15, FD16, FD19 |
| `erx_pthread_create_executor` | ERTS's normal and dirty CPU schedulers, through `ethr_thr_create`; a program's event executor, in `liberx`'s program layer | natively musl's `pthread_create` with the executor class, in the row above; hosted a start wrapper ([Making an executor](design-runtime.md#threads-and-synchronisation)) | `pthread_create`'s; no free index or slot `EAGAIN` | FD14 |
| `erx_release_entry` | `erx_prim_file.c` | in the root and hosted, local: `erx_pack_entry_at` and `erx_pack_path_at` over the archive `erx_pack_open` accepted, counting from the first path under `system/`. In a task, a service request naming the boot information's `release` and the index, answered from the slice's record: `index` counts from the slice's first entry, the path comes without its `domains/<name>/` prefix ([The production image](#the-production-image)), and it arrives in the caller's public UTCB in pieces of at most `utcb_bytes_max` bytes, so the stub loops for a longer one | path, size, offset from `release_addr` and the entry's kind, a file, an image or an empty directory; an index past the run `ERX_ERANGE`; in a task, a `release` that is not a slice `ERX_ETYPE` | FD6, FD11 |
| `erx_space_create`, `erx_space_stop`, `erx_space_pause`, `_resume` | the domain library, for every domain, through `erx_space_create_domain`, the root-only form whose request, `domain_space_create` of `fiasco_call`, is `space_create`'s followed by the domain's band, its sub-spaces' band, its thread, object and mapping limits and its grant's CPU set ([Bands](#bands)); a session's port driver, for each program's anchor and image; the test-task launcher in the root (`libc-test` M3), through `test_space_create`, which also marks the task as a test task ([The console](#the-console)); job control and `fork`'s copy, for a pause ([design-programs.md](design-programs.md)) | service, from any task: `l4_factory_create_task`, with a handle table of `cap_limit` entries; `parent`, `fault`, `label` and the budget recorded ([Spaces, parents and exit records](#spaces-parents-and-exit-records)); the task's domain row and band recorded, a new domain row with the request's band for `domain_space_create`, else the creator's domain row and its sub-space band ([Bands](#bands)); a stop is [task exit](#task-exit) of the space and of every space below it, children first | the exit record at the fault gate once every thread of the space is deleted; a `parent` or `fault` handle that fails the lookup answers that failure unchanged ([Handles](#handles)), a stale one `ERX_ESTALE`, and one naming a live object other than a space for `parent` or a gate for `fault` `ERX_ETYPE`; a space handle is only ever in its creator's table, so a `parent` that passes the lookup is the caller's space or one it created; `cap_limit` past `ERX_CAPS_MAX`, or one whose window of IRQ slots would pass Fiasco's object space ([Handles](#handles), FD1), `ERX_EINVAL`; `ERX_SPACE_JIT` from a task other than the root whose own space is not a JIT space `ERX_ERIGHTS`; `domain_space_create` from a task other than the root `ERX_ENOTSUP`, as `test_space_create`, and a band outside the limits record's band enum `ERX_EINVAL`; `erx_space_pause` answers once every thread of the space is held at its gate, or `ERX_EDEAD` once the pause's deadline has ended the space, and `_resume` lets each held thread go on ([The pause](#threads-bands-and-stops)); a space past the domain's object limit `ERX_ELIMIT`; `_clear_caps`, `_quiesce` and `_copy` `ERX_ENOTSUP` | FD1, FD9, FD17, FD20, FD21 |
| `erx_gate_create`, `erx_gate_bind`, `erx_ipc_wait` | the domain library's fault thread and each domain's gate worker, serving fault gates; a runtime's urgent scheduler, for the objects bound to it | service: a gate is a record with a queue of fault and exit records and the one thread bound to it; a wait takes the oldest record, or sleeps on the thread's semaphore until the service queues one ([Fault gates](#fault-gates)); a wait by a thread that IRQ objects are bound to is local, `l4_ipc_wait` with the deadline, and returns the label of the one delivery it took ([Urgency](#urgency), "A bind to a thread") | the record's words in the message registers of the caller's public UTCB, its space's label as the label; the deadline as for every wait; a bind replaces the gate's thread, and `ERX_CAP_NULL` unbinds it, as on erXos's kernel; a bind to a thread of another task `ERX_ENOTSUP`; a wait by a thread that neither a gate nor an IRQ object is bound to waits until its deadline; a gate bound to a thread that IRQ objects are bound to, or an IRQ object to a gate's thread, `ERX_ENOTSUP`; `erx_ipc_call`, `_send`, `_reply`, `_reply_wait` `ERX_ENOTSUP`, so no gate carries a message | FD3, FD19 |
| `erx_cap_dup`, `erx_cap_close`, `erx_cap_pass`, `erx_object_destroy`, `erx_object_info` | Erlang NIF handles, the launcher, the inspector; the domain library installing a domain's capabilities (`erx_dom_install`); a session installing a program's budget, group, channel, data area, code objects and pipe ends | service: the handle tables ([Handles](#handles)); a duplicate or a pass makes an entry at the rights of the source entry intersected with the mask, a pass in a space the caller created, from any task, and for an IRQ object calls the one placement function, which places the capability at the new entry's IRQ slot only when the entry's rights hold `TRIGGER` or `ACK` ([Handles](#handles), [Passing a handle](#passing-a-handle)); a close frees the entry and advances its generation; destroy deletes the Fiasco objects, for memory revokes every mapping first, and for a budget deletes everything charged to it; `erx_object_info` as [Reporting kernel objects](#reporting-kernel-objects) says | a stale handle, a handle used after its own close, and a value that names no entry `ERX_ESTALE`, in every service call, but at the reserved values a call's row names ([Handles](#handles)); a close of an entry whose object was destroyed frees the entry, and takes a holder off the record only while the record's generation is the entry's; a ring or an acknowledgement through an IRQ handle after its own close reaches what the root has placed at its slot since (FD1); a right the source entry lacks stays absent whatever the mask; destroying a started thread, or a group that still has a thread, `ERX_ENOTSUP`; destroying an object from a task other than its creator's `ERX_ERIGHTS`, since no pass conveys the delete right; a pass from a space other than the caller's own, into its own, or of a space or gate handle `ERX_ENOTSUP`, as is an item naming the type its handle must have; a thread handle is no entry of the table, so no thread passes; a pass stops at its first refused item with that item's error, an item past a full table `ERX_ELIMIT`, and leaves the items before it passed, which the caller undoes (the domain library by its budget's destroy); the topics and fields that section names `ERX_ENOTSUP` or clear | FD1, FD3, FD4, FD5, FD6 |
| `erx_budget_create`, `_resize`, `_watch`; `erx_object_destroy` of a budget | the domain library: each domain's own and outer budgets and each connection's child budget; a session: each program's budget; the inspector | service, a create from any task and a resize from the root: a budget is a record of its parent and its wall, one number that is both its guarantee and its cap, with `used` and `carved` under `used + carved <= wall`: its user pages are charged to the record and refused past the wall, and its kernel memory is a Fiasco factory carved from its parent's ([Memory and budgets](#memory-and-budgets), [Budgets and groups as records](#budgets-and-groups-as-records)); its destroy deletes the budgets carved from it and everything charged to them | a handle per create; an elastic kind `ERX_ENOTSUP`, and a wall whose cap is not its guarantee `ERX_EINVAL`; a carve, or a resize that grows, past the parent's unspent wall `ERX_ENOMEM`; resize records the one wall, below the pages held plus the guarantees carved `ERX_EINVAL`, and a task's resize `ERX_ENOTSUP`; `used` partial (user pages, not kernel memory), `guarantee`, `cap` and `carved` exact, every other field `unsupported` ([Reporting a budget](#reporting-a-budget)); watch `ERX_ENOTSUP`; a charge past the cap, or past the kernel memory of the budget's factory, `ERX_ENOMEM`; a resize of the kernel-memory part `ERX_ENOTSUP` | FD25 |
| the time page, `erx_time_set_offset` | ERTS's time, deadlines | service: one pool page, recorded as a memory object of the root budget, holding the scale of the architecture's user-readable counter and the wall offset. The service maps it read-only into every task at the task's creation, at a constant address just above the task area, the thread table and its label page, that no `erx_vm_reserve` hands out; `erx_time_page` returns that address in a task and the page's window address in the root. Reading is local. `erx_time_set_offset(time_page, offset)` is a service call whose body checks the handle against the caller's entry, as every service call does: a handle that is not the time page `ERX_ETYPE`, and one without `WRITE`, which only the system domain holds, `ERX_ERIGHTS`, as on erXos's kernel; it then stores the offset as the page's, refusing one outside `0..time_offset_max` with `ERX_EINVAL` ([design-time.md](design-time.md#on-fiasco)) | correct layout; the boot information's `time_page` names the object and nothing maps from it | FD27 |
| `erx_entropy_read`, `erx_entropy_add` | ERTS's `crypto` seed, the host link, musl's `getrandom` | service: `liberx/backend/fiasco/entropy.c` over `rng.c`, keyed from the counter, then mixed with `/chosen`'s `rng-seed` and `kaslr-seed` where the device tree carries them (`kernel/core/rng_seed.c`), and on the Raspberry Pi 4 with the board's random generator on the condition of [Entropy sources](design-platforms.md#entropy-sources) ([The Raspberry Pi 4](#the-raspberry-pi-4)); each reply holds 16 bytes and each request 32, so the stubs loop | the banner names what went in, `erx: entropy: from /chosen/rng-seed (32 bytes), /chosen/kaslr-seed (8 bytes) and the counter`, or on the Raspberry Pi 4 `erx: entropy: from the RNG200 (32 bytes) and the counter`, or says `erx: entropy: quality: low, from the counter alone` when nothing else went in, followed on the Pi 4 by `, since the RNG200 gave too few words within 100 ms` or `, since the RNG200 could not be read` when its read failed. A release image never runs on such a seed, as [design-crypto.md](design-crypto.md) requires: its root counts the bytes that went in from sources other than the counter, the count the banner prints, and with fewer than 32, after the banner's line, writes `erx: entropy: refused: a release does not run without a seed` and ends the machine as `ERX_END_OFF` before it starts any domain, so no key, vault or authentication path ever runs on the counter alone; a development build prints the line and goes on, its banner saying `development build: trusted code only`. `entropy_quality` stays unreported; at most 256 bytes a call; a read the generator cannot serve `ERX_ENOTSUP`; `ERX_ENTROPY_CREDIT` `ERX_ENOTSUP`, since no source is trusted | FD26 |
| `erx_debug_log`, `erx_log_read`, `erx_log_take` | `liberx`, ERTS's crash path, test tasks; the Erlang log readers, of which the log service, `erx_syslog`, alone takes | service: [The console](#the-console) | correct | FD26 |
| `erx_backend_trace_read`, `erx_trace_read` | `erx_trace_ring:read/3`, for `erx:trace` | local, in the root: [The trace ring](#the-trace-ring) | the root's parks, wakes, IRQ deliveries and task starts and ends, reported by `liberx trace`; a cursor past the head, or `max` of 0 or over 512, `ERX_EINVAL`; an exhausted ring `ERX_ELIMIT`; `erx_backend_trace_read` in a task `ERX_ENOTSUP`; `erx_trace_read` `ERX_ENOTSUP` everywhere, so the kernel's row is `unsupported` | FD26 |
| `erx_watchdog_pet`, the crash record, `erx_machine_end(res, how)` | M1's criteria | pet: a local atomic store in the root, a task's call `ERX_ENOTSUP`, and hosted `ERX_OK` with no effect. End: the root's alone, a task's call `ERX_ENOTSUP`, as the kernel's `POWER` check leaves it to the system domain ([design-system.md](design-system.md#a-sessions-request)); [The end path](#the-end-path) | `ERX_END_OFF`, `_RESET` and `_PANIC` as erXos's kernel ends them; `ERX_END_TRIAL` `ERX_ENOTSUP`, before anything stops, while the boot value is `unknown`, and otherwise the platform's trial request made by the root and a reset, a kernel hang or a stalled watchdog is caught only on a board whose platform record names a hardware watchdog, from the start of the root's watchdog thread ([The watchdog](#the-watchdog)) | FD26, FD29 |
| `erx_firmware_request(resource, index)` | the device service's firmware worker: the VL805's notification, the Bluetooth line's power notifications, the Raspberry Pi 4's sensor readings | the root's alone, a task's call `ERX_ENOTSUP`; in the root, local, in the caller's thread, never in the root service, whose one thread serves every task. Having no resource objects, the backend takes the row as a value, `erx_firmware_request_row` of `liberx/backend/api.h`, which the domain library's firmware entries call with the row it resolved from the manifest; the root maps the mailbox's page, which the board's platform record names, keeps a page of its own image as the buffer, and runs the same C17 mailbox core as erXos's kernel, sleeping between reads ([The firmware request](#the-firmware-request), [design-kernel.md](design-kernel.md#firmware-requests), [design-board-sensors.md](design-board-sensors.md#the-kernel-call)) | erXos's kernel's ([design-kernel.md](design-kernel.md#firmware-requests)): the row's answer, at most its window, in the caller's UTCB; a deadline of 1 s from the call's start; `ERX_EBUSY` beside a request in flight, the trial request's included; every call after an `ERX_ETIMEDOUT` answered `ERX_ETIMEDOUT` at once; `ERX_EPROTO` for an answer outside the interface; `ERX_ENOTSUP` on a platform whose record names no rows, QEMU `virt` among them | FD29: the root task, in user mode, maps the mailbox |
| a thread's fault | a domain's or a program's fault; a test task's fault | [Faults](#faults-and-the-fault-of-the-root-task) | a fault record at the space's fault gate, thread `unknown`, the faulting thread left waiting; with no fault gate, a crash record and the task's end; the machine's end for the root | FD19, FD20 |
| `erx_vcpu_control`, `erx_vcpu_resume`; `erx_irq_bind` to a thread | `liberx`'s signals in programs (Track P) | [vCPU upcalls on Fiasco](#vcpu-upcalls-on-fiasco), over Fiasco's vCPU interface with no kernel change | correct for programs whose every kernel call keeps `liberx`'s event rule; no umtx wait ends with `ERX_EINTR`, and a delivery that arrives during a kernel call is taken at the thread's return to its own code; an arming whose kernel-user memory Fiasco refuses `ERX_ENOMEM`, nothing armed | FD23 |
| messages through gates, rendezvous passing, `erx_mem_own`, `erx_mem_dirty`, `erx_dma_*`, `erx_resource_carve`, `erx_space_quiesce`, `_clear_caps`, `_copy` | none | none | `ERX_ENOTSUP` | FD3, FD9, FD12, FD13 |

`erx_entropy_read` leaves the generator's bytes in the caller's UTCB, where the next call that writes the
message words, or anything that reads them, would find them. So no caller calls it but one:
`erx_entropy_take(out, len)` (`liberx/backend/core/entropy_take.c`, the same on every backend) makes the read,
moves the bytes into `out` and zeroes each message word that held them. `liberx/backend/api.h` declares only
the take; the read is declared in a header private to it, `liberx/backend/core/entropy_read.h`, so a caller
that names the read without that header fails to build, and the `entropy-take` chokepoint keeps the header and
the name to the take, the backends that define the read and the function-API set that tests it. musl's
`getrandom` row, `AT_RANDOM`'s bytes, the runtime's reference key and `erx_bytes:entropy/1` all take their bytes
through it.

### Reporting kernel objects

`erx_object_info` is a request on the root's service gate, answered from the service's own tables, except its
group topic, which runs `erx_group_info`'s local body. A bit of a report's `reported` field is set only for a field
the backend has with the attribute's full meaning. `erx_info_partial(topic)` (`liberx/backend/api.h`) returns the
fields of a topic the backend counts only partly, whose `reported` bits stay clear; the inspector turns the two
masks into statuses ([design-live.md](design-live.md#inspection-records)). The hosted backend returns the same
masks, except that its machine report leaves `build` and `boot_value` clear: they come from bootstrap's handoff,
and a macOS process has none. The ABI's layouts carry `reported`, but no partial bit and no reporter.

| Topic | Asked on | `reported` | Partial |
| --- | --- | --- | --- |
| basic | any handle | the topic is `ERX_ENOTSUP`: the handle's entry holds its type and rights, but no object id, which only the kernel has (FD2, FD6) | none |
| machine | the resource, which is ignored; a task other than the root `ERX_ENOTSUP` | `cpus_online`, the count of `l4_scheduler_info`'s CPU map, clear when that call fails; `uptime`, `liberx`'s clock (`erx_fiasco_clock_ns`, the generic timer's virtual count since the counter started, which QEMU starts at reset and a board's firmware at power-on); `build` and `boot_value`, the build identifier and boot value of bootstrap's handoff, which the program root keeps for the service before starting it (a root that does not keep them, such as a native test guest's, leaves both clear); nothing else, since no machine page is mapped ([The booted slot](#the-booted-slot)): `entropy_quality` stays clear, since `liberx`'s generator, not the kernel, holds the entropy, and keeps no quality of its own | `memory_total` and `memory_free`, the pool's ([Reporting a budget](#reporting-a-budget)) |
| cpu | as machine; a CPU outside that map `ERX_ERANGE` | nothing: not `idle_time`, since Fiasco, built with periodic ticks and without fine-grained CPU time, charges each tick to the thread it interrupts, so its idle count bounds the idle time neither from below nor from above | none |
| group | in the root, `ERX_CAP_SELF` or the root's own group's handle; any other group handle the caller holds, a domain's included, any other handle, `ERX_CAP_NULL` included, and any call before the root's group is up, `ERX_ENOTSUP` | `cpuset`, once a set was configured, `parked` and `ready`, read from the root's status page; not `capacity_mcpu`, since the grant's capacity is ignored, nor `used_ns` | none |
| budget | `ERX_CAP_SELF` in the root, the root's budget, or a budget record's handle in the root; any call from a task `ERX_ENOTSUP`, which the inspector shows as every field `unsupported` | a budget record's `guarantee`, `cap` and `carved`; nothing of the root's budget ([Reporting a budget](#reporting-a-budget)) | `used` |
| thread | `ERX_CAP_SELF` or a live task's space, any other handle `ERX_ENOTSUP`; `index` counts the task's created and started threads in the order of the service's task table, and one past the last is `ERX_ERANGE` | nothing: no state or wait kind, which only the kernel has | none |
| handles | a live task's space the caller holds, any other handle `ERX_ENOTSUP`; `index` counts the entries of the task's handle table in index order, and one past the last is `ERX_ERANGE` | the entry's number, its object's kind and the entry's rights ([What a test reads of a task](#reporting-kernel-objects)) | the object: the root's record, not an object id |
| mappings | as handles; `index` counts the task's mapping records in address order | the range, its object's kind and the mapping's rights | the object, as for handles |
| image entry | the boot image | the topic is `ERX_ENOTSUP`; `erx_release_entry` reads the index, in a task through the service | none |

The domain library creates every domain's group, so the root holds a handle to each, but the group topic
answers only the root's own group: another domain's group is `ERX_ENOTSUP`, which the inspector shows as
every attribute of `[domains, D, group]` `unsupported`. The root's group's `parked` and `ready` come from the
root's status page, which its own `liberx` writes under the park lock, and the kernel's own records are a
recorded difference. A thread's id is
its index in the service's task table (`liberx/backend/fiasco/service_task.h`), in the root's memory, which only
the service's own bodies change, as they create, start and delete the thread's Fiasco objects. So a thread listed exists, as the
kernel would say, and nothing in a task's own memory, its thread records included, is read for the listing. A
later thread reuses the index once the thread is reaped, where erXos's kernel gives each thread an object id of its
own, a recorded difference.

**What a test reads of a task.** A space's handles and mappings are one inspection topic on both kernels: the paths
`[domains, Id, capabilities]` and `[domains, Id, mappings]` of [design-live.md](design-live.md#paths), and the same two
below a program, which the session's agent relays from the capabilities it holds as the sub-space's creator
([design-live.md](design-live.md#inspection)). Their attributes are marked `build development` in `abi/inspection.txt`, so
a release build's inspector leaves them out on either kernel and they serve tests and development, not users. They come from
two topics of `erx_object_info` asked on a space, `handles` and `mappings`, each listing a page at a time, whose `index`
counts the space's records and one past the last is `ERX_ERANGE`. On Fiasco the root's own records of the task answer both,
which are true by construction ([Who holds what](#who-holds-what)): a handle's slot, its object's kind and the slot's
recorded rights, and a mapping's range, object kind and rights, each with its full meaning. A record's object is the root's
record of it, not an object id, which only the kernel has (FD2, FD6), so the backend marks that field partial and the
inspector shows it as `{{backend, liberx_placements}, {partial, Record}}`, under the backend reporter `liberx_placements`
that `abi/inspection.txt` declares as standing in for `kernel` ([design-live.md](design-live.md#inspection-records)). The
confinement test of the stopgap 0.2 ships in a sub-space, LVGL's renderer
([design-display.md](design-display.md#lvgls-release-contract)), reads the program's handles and mappings through `/proc`,
so it runs unchanged on a development build of either kernel, against the same placement code a release runs. A test reads
slots and mappings apart: a program holding a mapping of an object holds no slot for it unless it was passed one. The
test-task launcher and its `task_write` body (below) are compiled only into a development build's root, and the release
build check fails if the release root's symbol table names either, which its seeded case proves by building a release root
with the launcher left in.

## Downsides against erXos's kernel

Each row is a property of erXos's kernel that Fiasco does not have, on a development build and a
release alike, named `FD1` to `FD34` so that the call table, the hostile cases and other documents
cite it. This is the one list of differences. A row's Weakens column names what it weakens: the K
items of [design-kernel.md](design-kernel.md#invariants) and the rules of CLAUDE.md that erXos's
kernel keeps and Fiasco does not, and the numbered properties of other designs (D of
[design-domains.md](design-domains.md), F of [design-files.md](design-files.md), SH1 of
[design-shell.md](design-shell.md), P2 of [design-programs.md](design-programs.md)), or `none`
with what is missing instead. The other columns give the property lost, the mechanism Fiasco has
instead, what a user or an app sees, and what closes it. Results and refusals live in
[the call table](#the-call-table) alone, whose last column names the row; a difference that no row
holds is a bug in one backend. The "what would be lost" column of the
[L4 lineage](design-kernel.md#l4-lineage) gives the mechanism; this table gives what a user or an
app sees. Release notes and the user documentation carry it. Where a stage of plan.md's
[Track F](plan.md#track-f-fiasco-improved-to-the-decision) closes or narrows a row, the Closed by
column names it; what the stages leave closes on erXos's kernel only if plan.md's gate GF chooses
that kernel, and otherwise stays a published downside.

| Row | Weakens | erXos's kernel | On Fiasco instead | What it means | Closed by |
| --- | --- | --- | --- | --- | --- |
| FD1 | K1, K26 | a stale capability never names another object, whatever the use (K1); a table holds up to `caps_max` capabilities; a deleted object's queued threads wake with `ERX_ESTALE` or `ERX_EDEAD` (K26) | every service use of a handle checks the entry's generation, so a closed or stale handle answers `ERX_ESTALE` ([Handles](#handles)); but a ring or an acknowledgement of an IRQ object is the holder's own Fiasco invocation of the slot its handle's number fixes, and Fiasco checks no generation; a space's `cap_limit` is bounded by the IRQ slots Fiasco's object space holds; no queued thread is woken | a ring or an acknowledgement through an IRQ handle its holder has closed reaches whatever IRQ object the holder's entry holds next, and entries are taken first in, first out. That can be a spurious ring of another doorbell the holder holds (for a server, another client's), which costs that object's owner one wake, as any ring does. It can be an early unmask of a line the holder holds. Nothing is mapped, passed, bound or destroyed through such a handle. A space asks for at most the `cap_limit` that fits, which `erx_space_cap_limit_max()` answers. A domain keeps for its life the entries of a connect or a give that failed, whose values it never learned | stage F1 of [Track F](plan.md#track-f-fiasco-improved-to-the-decision), or erXos's kernel |
| FD2 | K1 | every thread and space has an object id of its own, and a thread's handle names it until it is reaped | a thread is an index of its task's table, carried with no generation by its handles, by `erx_object_info`'s thread ids, by the trace ring's `thread`, `space` and `target` and by an exit or fault record's `space`, and kept past its space's deletion (by a join, a release or the deletion of a space above it) it can name a thread of a space that reuses the index; a fault record's thread is `unknown` | a thread handle, a listed id or a record's `space` is good only while what it names lives; a receiver tells which space a record is for by its label | stage F1 of [Track F](plan.md#track-f-fiasco-improved-to-the-decision), or erXos's kernel (thread handles in the capability table) |
| FD3 | K17, K24 | gates carry messages and capabilities, with `ERX_EDEAD`, labels and deadlines, and capabilities pass at a rendezvous (K17, K24) | gates carry fault and exit records only, and capabilities move only by the root's `erx_cap_pass` | native servers in other domains are reached through connections only | erXos's kernel |
| FD4 | SH1, P2, CLAUDE.md "Functional core, effects at the edge" | a pass is planned whole, so a refused pass moves nothing | a pass moves its items in order and stops at its first refused one | the caller undoes a partial pass, the domain library by its budget's destroy | stage F1 of [Track F](plan.md#track-f-fiasco-improved-to-the-decision), or erXos's kernel |
| FD5 | D16, K3, K21 | an object lives by its budget and its references, and its creator's end does not delete it; a holder of the destroy right destroys it; a thread's destroy ends it at once, and a group's destroy ends its threads | an object also goes with the task that created it; only its creator's task destroys it; a started thread, or a group that still has a thread, is not destroyed | code must not keep an object alive by holding a handle to it in a task that is not below its creator; a thread ends by its own exit or its space's stop; D16's deletion by the system domain alone holds, since the domain library creates a connection's objects | erXos's kernel |
| FD6 | none (a missing report) | `erx_object_info` answers every topic, with object ids | the root answers what its own tables hold ([Reporting kernel objects](#reporting-kernel-objects)) | the inspector shows the rest `unsupported` or `partial`, with their reporter | narrowed by stage F1 of [Track F](plan.md#track-f-fiasco-improved-to-the-decision); erXos's kernel |
| FD7 | K6 | committed memory is populated lazily, with every page it can need reserved and charged at the commit, and a refused call keeps the parts before it (K6); a reserve without `ERX_VM_FIXED` searches below the placement base | a commit populates every page at once and a refused call keeps none of its parts; a reserve takes the lowest free range of its area | a committed page is present at once here, and no code reads timing or fault counts from it | erXos's kernel |
| FD8 | F6, K4, K5, K8, K9 | a mapping's protection moves only beneath a ceiling fixed from the capability that made it, and only a JIT space makes code (K4, K5, K9); no page is executable through one mapping while it is writable through another, by the CPU or a device (K8) | the root's range table keeps a record per mapping at the rights it was made with, and Fiasco's patched map refuses one mapping that is writable and executable ([The release's Fiasco build](#the-releases-fiasco-build)); `ERX_SPACE_JIT` gates only `ERX_MEM_JIT`, so an object with no flag can be mapped writable in one place and executable in another, and an unconfined device can write any page; the root's own mappings from `sigma0`, its image and its pool window, through which it reaches every page, are writable and executable at once (`l4re-core/sigma0/server/src/memmap.cc:96,125`) | any domain can run code it wrote into its own memory, so F6 holds by the file servers' and the session's own code alone; a stray write by the root to any page it reaches through its window can make code there | narrowed by stage F2 of [Track F](plan.md#track-f-fiasco-improved-to-the-decision); erXos's kernel |
| FD9 | F7, F8, K22, K23 | objects grow; paged objects are supplied on demand, a supply filling only pages not yet supplied; copy-on-write children, store tracking and a space's copy, quiesce and capability clearing (K22, K23) | none of them; a supply writes every page of its range; `erx_mem_child` copies its whole range when it is made, so a loaded executable's writable segments cost each program their full size at its start and share no page, and a child outlives its parent's deletion | no copy-on-write `fork` and no shared file mappings written back by store | narrowed by stage F7 of [Track F](plan.md#track-f-fiasco-improved-to-the-decision), the root as pager under Track Q's first consumer; erXos's kernel |
| FD10 | K16 | an image map refuses another ABI version and a range in use each with its own status and keeps no part of a failed load; slicing is checked against `SYSTEM`; no file is read or mapped before its check (K16) | the root plans and maps images, keeping the segments a failed load mapped until the space ends; a file entry's hash is not checked and its segments are copied into each space; slicing checks no file; a slice's destroy revokes its entries' pages from every space; the root maps the whole archive read and execute, its files included, and its own image read, write and execute from `sigma0` | a damaged file entry is not caught at its map, and a stray write to the root's code or read-only data does not fault | stage F2 of [Track F](plan.md#track-f-fiasco-improved-to-the-decision), or erXos's kernel |
| FD11 | CLAUDE.md "Untrusted input" | `erx_mem_copy` and an image entry's listing run in the kernel, through its own mappings | the root copies through its window, forward over overlapping ranges of one object, and lists a task's entries on its own thread | copies and listings take the root's time (FD17) | erXos's kernel |
| FD12 | K4, K8, K22, CLAUDE.md "Trust placement" | every device's DMA reaches only the windows its driver maps (`erx_dma_map`), MSIs go through a frame the kernel drives, device buffers live by their references, and each board has its device secret (M9, M12) | a device is confined only by a DMA space behind an IOMMU, and no device of 0.2's platforms is behind one ([Devices](#devices)); MSIs are lines of QEMU `virt`'s MSI frame and of the Raspberry Pi 5's MIP | the domain that holds a DMA-capable device can reach all memory through it, so that domain is in the trusted base, and on the Raspberry Pis a compromise of any driver that masters DMA (the network domain's, which parses packets, the storage domain's, the USB domain's, which parses what any USB device sends) is a compromise of the machine; the devices that can write the MSI frame can raise one another's lines | erXos's kernel (M9's kernel part); M12 (the secret) |
| FD13 | none (missing calls) | resources are carved (`erx_resource_carve`) and a domain makes physical objects and lines within a carved resource's rights; `erx_irq_route` applies a route; an IRQ object moves between groups | the root alone makes physical memory, contiguous memory, lines and MSIs, from the manifest's device entries; no carve, route or move between groups; every holder of an IRQ object can acknowledge it, since Fiasco's acknowledgement checks no right ([Rights](#rights)), where erXos's pass set gives `trigger` without `ack` | a device reaches a domain only by the domain library's give; a ringer's acknowledgement of a peer's doorbell does nothing, since a software object has no line to mask, and a device line is placed only in the domain that holds its device | narrowed by stage F3 of [Track F](plan.md#track-f-fiasco-improved-to-the-decision) (the acknowledgement's right); erXos's kernel |
| FD14 | D12, K3 | a domain's objects are bounded by its budget alone | they are bounded also by its row's thread, object and mapping limits ([Memory and budgets](#memory-and-budgets)); a task holds at most 128 threads, a record waits for Fiasco's marker write before reuse, and a failed start that did not reach Fiasco's kill path loses its index until the task ends ([Table sizes](#table-sizes)) | a domain is refused at a limit while its budget has memory free, so its row is sized at its largest; D12's bounds hold at those limits | narrowed by stage F2 of [Track F](plan.md#track-f-fiasco-improved-to-the-decision); erXos's kernel |
| FD15 | CLAUDE.md "Trust placement", CLAUDE.md "ERTS is a parts bin" | CPU grants to runtime groups, quotas charged up the group tree, own-group charging, `erx_group_configure` enforced with usage reported, a group's threads in any space, a thread on any CPU of its mask | priority bands with no rank among the configured domains, CPU sets and thread limits ([Threads, bands and stops](#threads-bands-and-stops)); a group's grant is a record, of which Fiasco honours the CPU set and the slice; its threads run in its home task, and affinity runs a thread on one CPU of its mask, narrowed to its domain's CPU set | the ordinary work of the system domain, the drivers and the interactive domains shares each CPU round robin with the root service, in proportion to its ready threads, whatever a grant's quota, and none of them runs ahead of another; a root- or driver-band runtime whose `high` work does not end takes its urgent scheduler's CPU from everything below the urgent level; while configured domains keep a CPU busy, the app level's threads placed on it do not run, and an app spinning shares the app level in proportion to its threads; CPU use per domain is reported as `unsupported`; M10's "one runs out of CPU alone" holds between the app level and the levels above it, not within a level | stage 5 of [the scheduler](#stages-beyond-bands), in stage F5 of [Track F](plan.md#track-f-fiasco-improved-to-the-decision), or erXos's kernel |
| FD16 | none (performance) | the cooperation ladder: status words, deferred preemption, published urgency within the group's ceiling, group park in the kernel with the executor switched, capacity advice the kernel stands behind | urgency as a thread's fixed level alone, its band's base or ceiling, which no hint moves, so a runtime's urgent work runs on a scheduler of its own ([Urgency](#urgency)); park and wake go through semaphores and a dispatcher thread per task ([The park protocol](#the-park-protocol)) | ERTS behaves as stock BEAM does on a general-purpose kernel: it spins briefly and backs off on a lock whose holder is preempted, and a wake, a doorbell's included, goes through one more thread switch; its schedulers park without busy waiting, so every idle moment pays that path ([Scheduling](#scheduling)) | stages 1 to 4 of [the scheduler](#stages-beyond-bands), in stage F5 of [Track F](plan.md#track-f-fiasco-improved-to-the-decision), or erXos's kernel |
| FD17 | K31, CLAUDE.md "Untrusted input" | a kernel call runs on the caller's own thread and is charged to its own group, so what one domain makes another spend is bounded and declared; a fault of the root task ends the machine at once (K31) | setup, faults, copies and every service call run on the root service's one thread at the base level, which it shares with every configured domain's ordinary work ([Bands](#bands)), or on a same-CPU caller's remaining slice and at its level until the first reschedule, Fiasco's loan of a caller's time, which erXos keeps ([Scheduling](#scheduling), "A call's slice"), and a program's start costs one service request per object; a long body (a space's release, which finishes its tree's teardown, a budget's destroy and its sweeps of the object table, and a stopped task's deletion, the teardown's longest piece) delays every other | an app flooding the root with requests or faults takes CPU from the configured domains' ordinary work on the root's CPU, the system domain's, the drivers' and the display's alike, since none is ranked above the root service and all share its level round robin, and from the app level there; it delays urgent work, which runs above the base, only while that work waits on a request to the root ([Urgency](#urgency), "What it bounds, and what it does not"); and it delays every other domain's setup and faults, which 0.2 accepts; a fault of the root service hangs every client until the watchdog or the harness's deadline ends the run | erXos's kernel |
| FD18 | K20 | the executor rule refused by the kernel | `liberx`'s stub refuses it | a runtime that bypasses `liberx` can stall its own executors, harming only itself | erXos's kernel |
| FD19 | none (missing calls) | threads are backed and charged at their create, any number run in a space the caller holds, a start resumes a repaired thread, and `erx_thread_stop`, `_read` and `_write` work | a creator starts only a space's first thread; a faulting thread waits until its space stops; no stop, read or write of a thread; a gate's thread is of the gate's own task | no debugger or pager repairs a thread | stage F3 of [Track F](plan.md#track-f-fiasco-improved-to-the-decision), or erXos's kernel |
| FD20 | D7, D17, K18, K27, K28 | a stop's bounded finishing path (K18, K27) and fault and exit records from the kernel with the thread's identity (K28) | the root stops a tree children first and posts each exit record, at the gate fixed at creation, after every thread's deletion has returned and the space's teardown has given its memory back; a fault's record comes from a pool of its space; a fault message's words are the task's own | an exit record arrives when the root's teardown of the space completes, with no bound under hostile load, so D7 and D17 hold without their bound; a dead domain's write position is final when its end is reported; a task that reaps faulted threads and faults again can run its own pool out and lose its own records, and its raw IPC can put stale numbers in its own crash record | erXos's kernel |
| FD21 | K30 | a whole-space hold that every call it started runs out under (K30) | the root holds each thread at its gate ([The pause](#threads-bands-and-stops)) | `fork` and job control work; a thread in a kernel call is cancelled out of it and retries after the resume; a thread of the paused space can make its own space's pause return early, and a space whose threads do not all arrive within the deadline ends | erXos's kernel |
| FD22 | none (a missing call) | umtx in the kernel, across spaces, with `ERX_EFAULT`, `ERX_ESTALE` and `ERX_EINTR` | umtx within a task ([The umtx table](#the-umtx-table)) | no futex in memory shared between programs | erXos's kernel |
| FD23 | K29 | vCPU upcalls with no event lost (K29), events ending a wait | the subset of [vCPU upcalls on Fiasco](#vcpu-upcalls-on-fiasco), over a vCPU state area its program can write, harming only itself, since the resume validates the frame and Fiasco sanitizes what it restores (`task.cpp:93-116`, `arm/64/context-arm-hyp-64.cpp:27-35`) | signals in programs arrive late around waits and raw kernel calls, and `sem_wait` never fails with `EINTR` | narrowed by stage F3 of [Track F](plan.md#track-f-fiasco-improved-to-the-decision); erXos's kernel |
| FD24 | K7, K10 to K15, K20, K33, CLAUDE.md "Untrusted input", CLAUDE.md "Kernel stacks are proven", "Chokepoints are build checks" and "The ABI and the hardware each have one source" | a kernel built under erXos's construction rules: the stack proof, recursion only through `musttail`, the kernel chokepoint checks, generated register access, a generated kernel ABI, one route from user mode, once-only reads of every user-writable field (K7), no panic on a user thread's input (K12), bounded kernel paths (K13), and K10, K11, K14, K15, K20 and K33 by construction | Fiasco's C++, its 8 KiB thread block measured by the conformance suite's watermark (`kernel/stack_fiasco.txt`), never proven; each of those properties holds only as far as Fiasco's own code gives it | a Fiasco defect reachable from a domain's capabilities can break isolation; the system-call fuzz campaign and the upstream watch are the defence; that the kernel never loads or stores through an address a domain supplies, and reads each user-writable field once per decision (K7), holds only as far as Fiasco's own code gives it, which no erXos audit checks | erXos's kernel |
| FD25 | D12, D16, K3, K32 | budgets with caps above guarantees, borrowing, every charge returning at once, a resize of the whole, a watch, and exact `used` for every budget (K3, K32) | every budget is a wall at its guarantee, `used + carved <= wall` checked at every charge, carve, resize and destroy, a carved budget's kernel memory a share fixed at its creation ([Memory and budgets](#memory-and-budgets)); only the user-page part resizes; each budget record counts the user pages charged to it, and its kernel memory is not counted; a destroy is the root deleting everything charged to the budget | a program is refused while its session has memory free in another part, or is sized at its largest; an app shares the `apps` wall with the others only through the principal's wall the domain service carves for each session and destroys at its retire, as on erXos's kernel ([design-packaging.md](design-packaging.md#an-apps-principal)); D16's charging of a connection to its child budget holds, at walls | narrowed by stage F6 of [Track F](plan.md#track-f-fiasco-improved-to-the-decision); erXos's kernel |
| FD26 | K19, K31 | the kernel's trace ring, entropy, log, watchdog and deterministic mode at the kernel's level (K19, K31) | the root's, in user mode ([The trace ring](#the-trace-ring), [The console](#the-console), [The watchdog](#the-watchdog)); entropy is `liberx`'s generator in the root, and a read's bytes stay in the Fiasco UTCB message registers of the reader and of the root service until a later message long enough overwrites them, and in whatever registers and stack spill slots the compiler used on both sides | the inspector's kernel row is `unsupported`; a kernel hang or a stalled watchdog thread is caught only by the board's hardware watchdog or the harness's deadline; a record still in the ring, the root's own C output among them, is lost at a watchdog end or an end on a thread other than the root service's ([The end path](#the-end-path)); the crash frame and a kernel stop's report may interleave with a writing console driver and a task's frame with the watchdog end's; after the handoff the kernel's own lines reach the log only at the log service's next take, are lost with the kernel's 4 KiB ring at a hang, are lost with the root's untaken records at a kernel stop once a take has moved them, and at the machine's end come out ahead of untaken log records older than them; in a development kernel the console's driver stops being the UART's only user when the debugger takes the console, for the rest of the run if the operator resumes, with the UART's receive interrupt on under the driver, and for the whole run when `-wait` or `-jdb_cmd` enters the debugger before user mode ([The kernel's lines](#the-kernels-lines)); in a boot that never takes the log, a test root's or a partial boot's, the kernel writes the UART whenever it prints, as upstream does; deterministic mode's comparison starts at erXos's banner, or at the root's first line if Fiasco's own boot proves not deterministic | erXos's kernel |
| FD27 | none (an address) | the runtime maps the time page from its boot information's `time_page` | the root maps the page read-only into every task at its creation, at a constant address | a task's time page is at one address it cannot move or unmap | erXos's kernel |
| FD28 | CLAUDE.md "Trust placement" | the startup proof, `erx_root_plan` run by the packer and the kernel, with its charge evidence, and every property of the system manifest checked | the root startup rule, and the manifest check refuses the records of properties outside its scope ([The Phase 1 manifest check](#the-phase-1-manifest-check)) | a manifest that uses those records does not build | erXos's kernel (Track K's first part, before GK3); M9 and M11 for the refused records |
| FD29 | K31 | each board's platform items: the hardware watchdog, the crash region, the trial request and the device secret | on the Raspberry Pi 4 and the Pi 5 alike: the root's watchdog thread, which arms the board's power-management watchdog on every boot and reloads it, so a hang of Fiasco or of the root resets the board, with nothing behind the stretch before that thread starts, since the board's `config.txt` leaves `kernel_watchdog_timeout` unset and nothing under Fiasco would reload it earlier ([The watchdog](#the-watchdog)); a crash record on the console alone; the boot value as the firmware reports it; the trial request made by the root through the mailbox ([The end path](#the-end-path)); the firmware requests, each a row the domain library resolved from the manifest and the root's own code sends in the caller's thread ([The firmware request](#the-firmware-request)); `sealing` `none` ([The Raspberry Pi 4](#the-raspberry-pi-4)) | a crash leaves no record but the console's; that the caller of a firmware request chooses neither the tag nor the argument holds only against other domains, since the system domain's code shares the root's address space, which maps the mailbox's page for the boot, and could post any request, the board's key read among them; a hang before the root's watchdog thread starts, in the firmware's stage or in Fiasco's boot, stays hung until the power is cycled; and nothing is sealed to the board | M12; stage F4 of [Track F](plan.md#track-f-fiasco-improved-to-the-decision) for the stretch before the root's watchdog thread starts |
| FD30 | CLAUDE.md "Trust placement" | no table of the root's at all | the root's own bookkeeping: `erx_fiasco_task_join` trusts its caller, since its stub waits on the ended semaphore of the task index the service named, so a space deleted by another root thread between the answer and the wait leaves the stub spinning on the empty slot, and an index reused in that window takes another join's up (the launcher joins from one thread); a label naming no live task is counted, and nothing reads the count | no domain sees them | stage F1 of [Track F](plan.md#track-f-fiasco-improved-to-the-decision) |
| FD31 | F4, CLAUDE.md "Untrusted input" | a client spends a server's CPU only within the server's admission, on grants the kernel enforces | a service serves requests on its own threads at its own band, and service grants are records ([Consumers that name grants](#consumers-that-name-grants)) | a client makes a service spend that service's band: an app flooding its session, or a file, storage or network server, turns its own low band's CPU into the server's higher band's, delaying that band's other work and every band below it on those CPUs; the same holds for a doorbell's ringer, which makes the holder's dispatcher run, and wake a parked executor, once per delivery at the holder's base level, never above it, however rarely the holder takes its readiness ([Interrupts and readiness](#interrupts-and-readiness)), and for a client whose messages a process of priority `high` in a root- or driver-band runtime handles, which carries that work to the urgent level within the bound the runtime's urgent roster states, as every session's console output reaches the Raspberry Pi 4's mini UART driver ([Urgency](#urgency), "What reaches the urgent level"); the network domain's CPU grant and per-interface ingress budget are no guarantee | stage 5 of [the scheduler](#stages-beyond-bands), in stage F5 of [Track F](plan.md#track-f-fiasco-improved-to-the-decision), or erXos's kernel |
| FD32 | CLAUDE.md "Trust placement" | branch prediction hardened at every entry from user mode and every switch between address spaces, as [design-arch-aarch64.md](design-arch-aarch64.md#speculation-mitigations) chooses from the CPU | nothing: Fiasco's AArch64 entry makes no SMCCC `ARCH_WORKAROUND` call, clears no branch history and has no speculation barrier, and its prediction barriers are built for AMD64 alone (`src/Kconfig:478-487`) | on a CPU open to branch-target injection (Spectre v2, CVE-2017-5715) or branch-history injection (Spectre-BHB, CVE-2022-23960), a domain may steer Fiasco's, or another domain's, speculative execution to leak memory through the caches; Arm's firmware records the Raspberry Pi 4's Cortex-A72 as affected by both ([Read in source, never run](#read-in-source-never-run)); under HVF a QEMU `virt` guest runs on the host's cores, whose exposure is unverified | [the release's Fiasco build](#the-releases-fiasco-build) if the null-request bench shows its entry patch costs nothing measurable, otherwise stage F4 of [Track F](plan.md#track-f-fiasco-improved-to-the-decision); erXos's kernel |
| FD33 | CLAUDE.md "Untrusted input", K12 | nothing a device does panics the kernel, and a fault ends only the faulting domain: an asynchronous error is contained at the device the platform's error records name, or at the thread a window presumes, and a fault of a domain's thread stops that thread with a typed fault record: CLAUDE.md's rule under "Untrusted input", with K12 for the asynchronous error the platform reports too late to attribute, the one exception that rule names | Fiasco's own interrupt, exception and asynchronous-error code, which no erXos test drives: the system-call fuzz campaign checks a domain's calls (FD24), not what a device does; how Fiasco handles an asynchronous error a device causes, or a storm of interrupts on a line, is unverified beyond what its source shows: an SError taken in user mode ends the task of the thread that runs, presumed its own (`arm_serror_user_entry`, `fiasco/kernel/src/kern/arm/thread-arm.cpp:713-735`), and one raised in the kernel, where SErrors are masked, lands on the next thread to enter user mode, so a PCIe configuration access or a USB controller's register access over a fallen link may end another domain's task ([design-pcie.md](design-pcie.md#on-fiasco), [design-usb.md](design-usb.md#on-fiasco)) | a device that misbehaves, or a driver that makes it misbehave, may hang or panic Fiasco and end the machine instead of the driver's domain | narrowed by stage F4 of [Track F](plan.md#track-f-fiasco-improved-to-the-decision); erXos's kernel; whether a release accepts it is [an open decision](#open-decisions) |
| FD34 | CLAUDE.md "Functional core, effects at the edge" | a range call that replaces a mapping is planned whole, its allocations made and its charge taken before anything changes, so the range is never unmapped between the old mapping and the new | the backend releases the old mapping, reserves the range again and maps the new object, with the range unmapped between the steps ([design-shared-code.md](design-shared-code.md#on-fiasco)) | a runtime that swaps a module's code ends its domain, with a diagnostic naming the module, when either of the last two steps is refused or when a thread that keeps running while thread progress is blocked, a dirty scheduler or an async thread, reads the code while the range is unmapped | stage F2 of [Track F](plan.md#track-f-fiasco-improved-to-the-decision) if Fiasco's overmap is atomic, or erXos's kernel |

## The scheduler on Fiasco

The two-level scheduler of [design-scheduler.md](design-scheduler.md) splits cleanly. Its runtime
half, ERTS's own scheduler (L2) and the runtime contract, needs nothing from the kernel beyond
threads, park and wake, and runs on Fiasco as under erXos's kernel, with one addition once stage 3
is built: the urgent scheduler of [Urgency](#urgency). Its kernel half (L1) maps onto Fiasco as
follows.

| Mechanism of design-scheduler.md | On Fiasco in the first release |
| --- | --- |
| ERTS's run queues, priorities, reductions, stealing (L2) | as under erXos's kernel; with stage 3, a root- or driver-band runtime runs its processes of priority `high` on an urgent scheduler of its own, whose run queue balancing and stealing leave alone ([Urgency](#urgency)) |
| park and wake, epochs, the group's ready list ([Park and wake](design-scheduler.md#park-and-wake)) | the backend's park protocol over a semaphore per thread and a dispatcher per task ([The park protocol](#the-park-protocol)), unchanged; doorbells are triggered directly |
| urgency per executor ([Urgency resolution](design-scheduler.md#urgency-resolution)) | the thread's Fiasco priority, its band's base or ceiling ([Bands](#bands)): a thread runs at the base unless it set its own urgency above its group's base, once, with `erx_thread_set_urgency` ([Urgency](#urgency)); no hint is sampled, and no executor's level moves |
| ready queues by urgency, round robin within a level | Fiasco's fixed-priority scheduler: priorities 1 to 255, round robin within a level, a quantum per thread, its grant's slice (`sched_context-fixed_prio.cpp`) |
| quotas and charging up the group tree ([Charging and quota](design-scheduler.md#charging-and-quota)) | none: Fiasco charges a thread's own scheduling context only |
| deferred preemption ([Deferred preemption](design-scheduler.md#deferred-preemption)) | none |
| status words and capacity ([Status words and capacity](design-scheduler.md#status-words-and-capacity)) | none; capacity is the configured advice in the status page, which nothing in the kernel stands behind |
| executor class enforcement ([Executor class enforcement](design-scheduler.md#executor-class-enforcement)) | `liberx`'s stubs |
| placement and affinity | each thread's mask narrowed to the domain's CPU set (`cpuset`), through `l4_scheduler_run_thread` ([Threads, bands and stops](#threads-bands-and-stops)) |

### Bands

Fiasco's scheduler knows priorities and nothing else, and four of its properties decide what a
priority can be used for:

* **No quota.** A ready thread waits for every ready thread above its priority on its CPU, however
  long they run (`Ready_queue_fp::next_to_run`, `ready_queue_fp.cpp:100-104`).
* **Round robin within a priority.** Threads of one priority take turns, a quantum each: a thread
  whose quantum ends goes behind the others of its priority (`Timeslice_timeout::expired`,
  `timeslice_timeout.cpp:36-48`; `Ready_queue_fp::requeue`, `ready_queue_fp.cpp:155-164`).
* **A wake preempts its equals.** A thread that leaves a wait takes its CPU at once from a running
  thread of its own priority or a lower one: the running thread keeps the CPU only if its priority
  is strictly higher (`Sched_context::Ready_queue::deblock`, `sched_context.cpp:120-148`;
  `Sched_context::dominates`, `sched_context-fixed_prio.cpp:261-264`; `Context::activate`,
  `context.cpp:1060-1067`; a semaphore's wake is `activate`, `semaphore.cpp:80-99`). So a thread
  that blocks hears of its work at once, and a thread that is ready but not running waits its turn.
* **No migration.** A thread runs on the one CPU it was placed on ([Scheduling](#scheduling)), so
  a thread behind a busy CPU's work is not helped by an idle CPU.

From them follows the one rule the bands are built on: **a priority above another is only for work
that ends.** Work that may run without end, which is every runtime's ordinary work, runs at one
priority, where round robin lets none of it starve the rest. A priority above it is held only while
a thread does work that an event started and that finishes, an interrupt's handling first of all.
Code the system does not trust runs below both, since nothing else on Fiasco bounds what it takes.

There are four priorities:

| Level | Priority | What runs at it |
| --- | --- | --- |
| watchdog | 255 | the root's watchdog, which takes no lock |
| urgent | 3 | a thread that waits for urgent work ([Urgency](#urgency)): the urgent scheduler of a runtime whose band reaches the level |
| base | 2 | the ordinary work of the root task and of every configured domain: the root service, and every thread of a runtime but its urgent scheduler |
| app | 1 | code the system does not trust: an app's session, the programs of every session, and a domain a principal requests |

A **band** is the range of levels a task's threads may run at, a base and a ceiling. A thread
starts at its band's base and never runs above its band's ceiling:

| Band | Base | Ceiling | Whose threads |
| --- | --- | --- | --- |
| watchdog | watchdog | watchdog | the root's watchdog |
| root | base | urgent | the root task's own: the root service, which stays at the base ([Scheduling](#scheduling), "A call's slice"), and the system domain's threads |
| driver | base | urgent | the driver and device domains, and the spaces below them |
| interactive | base | base | the display, web and session domains |
| app | app | app | an app's session, the programs of every session, a domain a principal requests |

The levels' priorities and the bands' two levels are one table of the Fiasco backend, which every
thread start reads, the root service's and the watchdog's included, and no priority leaves the
backend: the manifest names a band, never a number. Priority 1 is the lowest Fiasco gives a
thread, so no thread runs below the app level. The domain-limits record's band enum holds only the
three bands a domain may run at, `driver`, `interactive` and `app`; the root and watchdog bands
belong to the root task's own threads and have no name in the manifest, so no domain can be
configured at them. This is L4Re's shape: ned gives each program a range of priorities,
`prio_offset` to `prio_limit` ([Threads, bands and stops](#threads-bands-and-stops)).

**What the bands give.**

* *An interrupt's driver gets the CPU promptly.* The urgent scheduler its line is bound to waits
  for it blocked at the urgent level, so the delivery takes its CPU from every thread but the
  watchdog, another urgent scheduler running there included, since a wake preempts its equals,
  and the driver's process runs on that thread ([Urgency](#urgency)).
* *No domain's busy threads starve a driver, or any configured domain.* Nothing but the watchdog
  and urgent work runs above a configured domain's ordinary work, and urgent work is only what a
  trusted runtime runs at `high`, work that is bounded for each message whatever its
  sender, so what an untrusted party sends reaches the urgent level only within a bound its
  roster entry states ([Urgency](#urgency), "What reaches the urgent level"). At the base level every
  ready thread gets its quantum in turn, a busy loader of the system domain beside a driver's and a
  session's threads. A configured domain that blocks loses nothing to one that spins beside it,
  since its wake preempts the spinner.
* *Untrusted code delays no configured domain.* A thread at the app level runs only while no
  thread at the base or urgent level is ready on its CPU, and nothing an app sends changes its
  band.

They give no share and no bound. A configured domain's ordinary work gets a CPU in proportion to
its ready threads there, whatever its grant's quota; a root- or driver-band runtime whose urgent
work does not end, such as a process of priority `high` that is fed without end, takes its CPU
from everything below the urgent level; and while the configured domains
keep a CPU busy, the app level's threads placed on it do not run (FD15).

The configured domains are not ranked among themselves. A rank would put ordinary work that does
not end above other ordinary work, and with no quota that is starvation: with the system domain
above the drivers, a busy loader in it keeps every driver, session and app off its CPU, and with
the drivers above the system domain, a network or storage domain kept busy by its clients'
requests (FD31) keeps the console and the restarter off theirs. Either way the root service would
run at a different priority from some thread it shares a lock with. Urgency orders what a rank was
wanted for, the handling of an interrupt before everything that can wait, and leaves the rest to
round robin.

**The evidence.** On the Raspberry Pi 4, a probe stamping Fiasco's interrupt entry, the
dispatcher's wake and the driver's receipt found the kernel's path under 10 us and the rest of a
0.6 to 6 ms delay spent with the driver's ERTS scheduler awake but not running, behind other
threads of its priority on its CPU; an executor that was parked ran within 3 us of its wake
(history repository, `pi4/2026-11-22-irq-probe/`, images C and E, commits de6a618 and 66b1a9e).
The mini UART's receive FIFO holds eight bytes, 0.7 ms at 115200 baud, so the console loses
pasted bytes. With five strictly ordered priorities, the system domain at the top, the
`system_domain` suite's load on one CPU kept the session and the app-band peer from answering (`tools/lib/erx/system_domain_regrant.rb`, the load of `LOADERS`
processes).

**How a task gets its band.** The root service records a band in every task row, beside the row of
the task's domain, starts every thread of the task at the band's base and runs at the band's
ceiling only a thread that set its own urgency ([Threads, bands and stops](#threads-bands-and-stops)). A task's band is fixed when
the task is made, from its domain row, and nothing the task or its creator sends afterwards
changes it:

* The domain library makes each domain's space through `erx_space_create_domain`, the Fiasco
  backend's root-only form of `erx_space_create`, declared beside its other root-only calls in
  `liberx/backend/api.h`; erXos's kernel has no such call, and the hosted backend refuses it as it
  refuses `erx_space_create`. Its request, `domain_space_create` of `fiasco_call`, is
  `space_create`'s followed by the domain's band, the band of every space below the domain, the
  domain's thread, object and mapping limits and its grant's CPU set and slice, and the service
  answers it only for the root, as it answers `test_space_create`
  ([The call table](#the-call-table)). The task it makes is a **domain row**, which holds those
  values and the domain's counts against its limits.
* Every other task names its creator's domain row and runs at that row's band for the spaces below
  it. The root service gives that band to every space a task creates and never takes one from the
  creating task.
* The root's own row is the system domain's domain row: the root band for its own threads, the
  app band for the spaces it makes with `erx_space_create` (the native suites' tasks and the
  launcher's test tasks), and no limits but the root's own tables.

So no task exists without a band, and a domain's band, limits, CPU set and slice reach the root in
the one request that makes the domain, which the domain library sends from its own thread while
the root service alone writes the root's tables ([Helper threads](#helper-threads)). The domain
library derives both bands of a domain from its limits record and its kind:

* a configured domain runs at its record's band, and so does every space below it, since its
  sub-spaces are its own work: a driver's native shim is a sub-space of the driver's domain
  ([design-system.md](design-system.md#sub-spaces)); a display domain whose device must be
  handled above the base names `driver` in its record, since the interactive band's ceiling is
  its base;
* a session runs at its template's band, and its programs, the user's code, at the app band;
* an app's session runs at the app band whatever its template's record names, as
  `erx_dom_plan_app_session` plans it with the `memory` the app's entry carries rather than the
  template's ([design-packaging.md](design-packaging.md#an-apps-session)), so an app, whose code is
  untrusted, and its programs never run beside a configured domain;
* a domain a principal requests runs at the app band, and so does every space below it: the
  request names no limits record, so nothing it carries can name a higher band, and what it asks
  for a band is overwritten as its origin is;
* a partial-boot domain runs at the band of the manifest's `native_limits` record, the record its
  runtime limits come from, and so does every space below it.

A band is a domain's, not a thread's, so a domain's background work runs in its own band. What a
domain asks of a service or of the root runs at that service's level or the root service's, not
its own, so a flood of requests is not held to the band it comes from (FD17, FD31).

The band is a declared class and not the grant's `base` and `ceiling`
([design-scheduler.md](design-scheduler.md#data-model)), because on Fiasco a priority is the only
wall. Under erXos's kernel an app may publish an urgency above the system domain's base, since its
quota bounds what it takes there; on Fiasco the same numbers would let untrusted code run above
trusted work with no bound, so what Fiasco needs from the manifest is who is trusted, which the
band says and the numbers do not. Of a grant Fiasco honours the CPU set and the slice.

### Urgency

Urgent work is work an event started and that finishes: the handling of a device's line, and in an
ERTS runtime a process of priority `high`, which is what a driver's interrupt path runs at
([design-shared-devices.md](design-shared-devices.md), "The owner"). The runtime decides what is
urgent, as under erXos's kernel; the band decides whether a thread may run above the base for it.

**The construction.** Urgent work has a thread of its own, which waits for it blocked at its
band's ceiling. Fiasco gives a CPU at once to a thread that leaves a wait and to no thread that is
merely ready ([Bands](#bands)), so the one thread sure to run when an event arrives is a thread
that was waiting for it, at a level above the work the event must interrupt. In an ERTS runtime
that thread is the **urgent scheduler**: a scheduler thread that runs every process of priority
`high` and no other, has the runtime's device lines bound to itself, and with nothing to
run waits for them in Fiasco. Three things follow, and the rest of this section is their detail:

* No thread's level moves. A thread is at its band's base or at its ceiling from its start to its
  end, so no thread ever has to raise itself, or be raised, to do urgent work.
* Urgent work is never held by a base-level thread. A line's delivery, its label and the `high`
  process it wakes pass only through the urgent scheduler, so nothing urgent waits for a thread
  that is awake at the base to get its turn there, which is the wait the Raspberry Pi 4 measured
  ([Bands](#bands), "The evidence").
* Fiasco is unchanged. A priority set by the holder of the scheduler capability and an IRQ object
  bound to a thread are both upstream's.

**What the proven kernels do.** None of them raises a ready thread for an event; each has the
event's handler wait for it at the handler's own priority.

* *Fiasco* delivers an interrupt as a message to the one thread its IRQ object is bound to, which
  takes it in an open wait at its fixed priority (`Irq_sender::send_local` and `send`,
  `irq.cpp:925-1009`). Only a holder of the scheduler capability sets a priority
  (`Scheduler::sys_run`, `scheduler.cpp:63-110`), and a thread runs above its own only on the time
  of a caller that waits for it ([Scheduling](#scheduling), "A call's slice").
* *seL4* signals an interrupt to a notification that a handler thread waits on
  (`seL4_IRQHandler_SetNotification`), under MCS lends a passive handler the notification's
  scheduling context while it handles the signal (`seL4_SchedContext_Bind`), and changes a thread's
  priority only for a holder of its capability, within the maximum controlled priority of an
  authority thread (`seL4_TCB_SetPriority`).
* *Zircon* has a thread wait for an interrupt object in `zx_interrupt_wait`, and applies a
  scheduling profile to a thread only for a holder of the thread's handle with
  `ZX_RIGHT_MANAGE_THREAD` and of a profile object (`zx_object_set_profile`). A waiter's priority
  reaches another thread only through the ownership of a futex (`zx_futex_wait`'s owner), whose
  rules were not read.

The files and lines are in [Read in source, never run](#read-in-source-never-run).

**The level.** `erx_thread_set_urgency(thread, urgency)` on the caller's own thread is a request
to the root service. The root records the thread's level in its thread row, the band's ceiling when
`urgency` is above its group's base and the band's base otherwise, and runs the thread at it with
`l4_scheduler_run_thread`, which changes a started thread's priority on its own CPU
(`Thread::start_migration` and `Thread::set_sched_params`, `thread.cpp:790-806`, `:695-711`). One
function builds every scheduling parameter the root hands Fiasco from the thread's row, so an
affinity change passes the same level again and a thread's level has one owner, the root. In a band
whose ceiling is its base the call succeeds and changes nothing. On any other thread it is
`ERX_ENOTSUP`: no consumer sets another thread's level. A thread makes the call once, at its start,
so what the request waits behind at the root service, the base level's requests, costs only that
start. That the sequence is right when the root service is running on the caller's own scheduling
context ([Scheduling](#scheduling), "A call's slice") is read and not run
([Verification](#verification), the urgent thread case at one CPU).

**A bind to a thread.** `erx_irq_bind(irq, thread, label)` binds an IRQ object to a worker thread
of the caller's own task, as the kernel interface binds one to a worker
([design-kernel.md](design-kernel.md#messages-gates-and-irq-objects)). The root, which alone binds,
gives the object a free entry of the task's label page, stores the label there and runs
`l4_rcv_ep_bind_thread(irq, thread, entry)`, as it does for a group with the dispatcher
([Interrupts and readiness](#interrupts-and-readiness)); the 64 entries are the task's, shared by
its group's objects and its threads'. The thread takes its deliveries with `erx_ipc_wait(deadline)`,
which is `l4_ipc_wait` with the deadline and returns the label of the entry Fiasco's label names.
A fire while the thread runs, or blocks in a umtx wait or a request, stays queued at the thread
(`Ipc_sender::send_msg`, `ipc_sender.cpp:176-181`) and arrives at its next wait, one delivery a
wait. A wait whose deadline is zero takes a delivery already queued and otherwise returns at once,
since Fiasco's receive takes a queued sender before it looks at the timeout
(`Thread::do_ipc_receive`, `thread-ipc.cpp:775-787`), so a thread that is busy can take what has
arrived without blocking. Nothing stands between Fiasco and the thread: no dispatcher, no ready
list and no semaphore.

What a line delivers depends on its trigger, for a thread as for a group. A level-triggered line
is masked at its firing and stays masked until its holder's `erx_irq_ack`
(`Irq_sender::_hit_level_irq`, `irq.cpp:1013-1033`), so it is delivered once for each
acknowledgement. An edge-triggered line, every MSI among them, since the backend sets each MSI's
line to rising edge (`irq_attach`, `liberx/backend/fiasco/irq.c:223`), is acknowledged by Fiasco
at the firing; a second edge before the first is received masks it, and the receipt unmasks it
(`Irq_sender::_hit_edge_irq`, `irq.cpp:1044-1090`; `Irq_sender::finish_send`,
`irq.cpp:751-776`), so it is delivered once for each receipt, whatever the holder acknowledges,
and edges between two receipts merge into one.

**The urgent scheduler.** ERTS's part is in
[design-runtime.md](design-runtime.md#scheduling); what it rests on in ERTS's source:

* *The thread.* One more scheduler thread, of the worker class, which the adapter starts when the
  runtime's boot information gives its group a ceiling above its base (`urgency_ceiling`,
  `urgency_base`; [Boot information](#boot-information)), which on this backend is a task of the
  root or driver band. It sets its own urgency to the ceiling at its start and is pinned to the
  first CPU of the runtime's run. A runtime in the interactive or app band starts none and runs
  `high` as stock ERTS does, on its normal schedulers.
* *Its place in ERTS.* Inside ERTS it is one more normal scheduler, the last, with its own
  scheduler data, run queue and allocator instance, so every table ERTS sizes by its count of
  normal schedulers and run queues holds it with no case of its own, the allocator's
  registration among them (`erts_alloc_register_scheduler`, `erl_alloc.c:1890-1903`). It is left
  out at five places, each an exclusion of its index: the counts Erlang reads,
  `erlang:system_info(schedulers)` and `schedulers_online`; a change of `schedulers_online`, which
  never suspends it; the balancer's migration paths, so balancing, immigration and stealing never
  take a process from its queue or give one to it; `process_flag(scheduler, N)`, which is
  `badarg` for its number as for any number past `schedulers` (`bif.c:2157-2165`); and the run
  queue of a new port, which a port opened on it takes from the first normal scheduler, where ERTS
  gives it the opener's (`erts_get_runq_current`, `io.c:346-353`). So no port is queued on it.
* *Its run queue.* Every enqueue that chooses a run queue passes `select_enqueue_run_queue`
  (`erl_process.c:6500-6553`), from `add2runq` (`:6743`) for a wake (`:6886`) and a spawn
  (`:13013`), and from a schedule-out (`:6675`). There a process that is not bound to a scheduler,
  and whose own priority, the one `spawn_opt` and `process_flag(priority, P)` set, is `high`,
  chooses the urgent scheduler's run queue, and every other process a normal one, as
  ERTS's balancer already sends a process to another run queue there (`erts_check_emigration_need`,
  `erl_process.h:2499-2516`). The rule reads the process's own priority, not the priority it is
  enqueued at, which a system task raises (`erl_process.c:6940-6944`), so a `normal` process
  running a task that a `high` process asked of it, a check of process code during a purge for one,
  runs it on its own normal scheduler ahead of that queue's `normal` work, as in stock ERTS. A
  bound process stays on the scheduler it is bound to, at whatever priority, as in stock ERTS. A
  process of priority `max`, which OTP reserves for the runtime's own processes, `net_kernel`, the
  distribution's connection owners and erXos's `erx_watchdog` among them, stays on the normal
  schedulers, where it runs before every other process of its queue, as in stock ERTS, so no
  distribution work reaches the urgent level.
  Dirty work takes the dirty branches of the same function (`:6511-6528`) and comes back through
  it. The moves that enqueue without it, immigration (`:4099`), the evacuation of a suspended
  queue (`:4356`) and the return of bound processes after a block (`:4185`), move processes only
  between the queues the balancer or a block names, which reach the urgent queue only in a
  block, below. So outside a block the queue holds exactly the runtime's runnable unbound
  processes of own priority `high`, and no normal scheduler holds one. A process whose
  priority changes keeps running where it is and moves at its next enqueue (`:9419`).
* *Its wait.* At every safe point, between two processes, it takes every delivery already queued
  at its thread with waits whose deadline is zero, dispatching each label as below, before it picks
  its next process; with an empty queue it waits in `erx_ipc_wait` until its next timer. So a
  delivery that arrives while it runs waits for the end of the running process's slice of
  reductions, not for its queue to empty. Another scheduler that queued it a process wakes it with
  `erx_irq_trigger` on a doorbell the adapter created and bound to it, the **wake bell**, where it
  wakes a normal scheduler with `erx_executor_wake` (`erl_process.c:1569-1573`).
* *Its lines.* `erx_device` binds a line to the urgent scheduler's thread in a runtime that has
  one, and to the group otherwise. The wait returns the line's label, the event table sends the
  driver's process its message, and the process, of priority `high`, joins this scheduler's queue.
* *A block.* `erlang:system_flag(multi_scheduling, block)` and `block_normal` promise that one
  normal scheduler alone executes (`erlang.erl:9634-9643`), and ERTS keeps it by suspending every
  run queue but the first and evacuating their processes to it (`erl_process.c:8429-8432`). The
  urgent queue is suspended and evacuated with the others, and while it is suspended the enqueue
  sends its processes to the first queue, so the block's one scheduler runs `high` processes with
  everything else, at the base. The suspended urgent scheduler runs no process: in place of its
  thread event it waits in `erx_ipc_wait` until its next timer, and dispatches each label it takes
  through the event table as aux work, which a suspended scheduler already runs
  (`suspend_scheduler`, `erl_process.c:7874-7897`), as stock ERTS's poll threads keep scheduling
  work during a block. So a line is neither lost nor held for the block's length, and its process
  runs on the first scheduler. A wake of the suspended urgent scheduler, at the unblock among
  others, rings its wake bell. Its processes return to its queue at their next enqueue after the
  unblock. A block of thread progress holds its lines until the block ends, as it holds every
  scheduler; they stay queued in Fiasco.
* *What Erlang code sees.* `high` processes run on one thread
  for the runtime, so two `high` processes never run at once, where stock ERTS may run them on
  several schedulers. They no longer wait for a `normal` process's slice of reductions or for its
  garbage collection, which stock ERTS makes them do. `normal` and `low` processes run meanwhile
  on the other CPUs, as with several schedulers of stock ERTS. A `high` process's dirty work stays
  on the dirty schedulers, at the base. A `max` process may run beside a `high` one, as a `max`
  and a `high` process may on two schedulers of stock ERTS, whose documentation lets processes of
  lower priority run in parallel with `max` (`erlang.erl:8229-8232`). `erlang:system_info(scheduler_id)` in an unbound `high`
  process outside a block names a scheduler past `schedulers`, a difference from stock OTP that
  `check-oracle` records with its test; the `multi_scheduling` cases of `scheduler_SUITE`
  (`scheduler_SUITE.erl:1315-1335`) and its bound-process cases (`:275-287`) must pass unchanged,
  and `check-oracle` runs them in a driver-band test domain, which has an urgent scheduler.

The size of the change to ERTS is an estimate from the functions named, 400 to 800 lines of
`erl_process.c`, `bif.c` and `io.c`, unverified.

**What reaches the urgent level.** A thread is above the base only in a task of the root or
driver band, where only trusted code runs: in the app band and the interactive band the ceiling is
the base, so `erx_thread_set_urgency` moves nothing there, an object bound to a thread there is
delivered at the task's own level, and neither an app nor a session gains a CPU by either call.
What reaches a thread at the ceiling is what is bound to it and what its runtime queues it:

* *A device line or an MSI.* The root alone creates and binds them, and installs each only in the
  domain the manifest names, which can pass it only to the spaces it created
  ([The call table](#the-call-table), `erx_irq_create` and `erx_cap_pass`), so only that domain
  and the devices, which can write the MSI frame ([Devices](#devices)), fire one. A
  level-triggered line is delivered once for each acknowledgement by its holder, so its driver
  paces it. An MSI is delivered once for each receipt ("A bind to a thread", above), so a device
  that raises one without end keeps the urgent scheduler taking deliveries as fast as it waits,
  each costing the driver's work for one delivery, whatever the driver acknowledges; nothing on
  Fiasco contains that but the device itself, which is FD33's interrupt storm.
* *A doorbell no one else holds.* In a task of the root or driver band the root binds a doorbell
  to a thread only while the task that created it is its only holder, and refuses the pass of a
  doorbell bound to a thread, both from the object's count of holders
  ([Passing a handle](#passing-a-handle)). So the wake bell is rung only by its own runtime, and a
  doorbell that any other task can ring is bound to a group, whose dispatcher runs at the base
  (FD31).
* *A runtime's priorities.* A process runs at `high` in a runtime that has an urgent
  scheduler only if the work each message makes it do is bounded whatever the message's sender,
  and only if it is on that runtime's **urgent roster**, a checked-in list that names, for each
  such process, the module that sets its priority, what makes it run and that bound. Who sends the
  message does not matter; how much one message can cost does. The release's roster:
  * the line owners of design-shared-devices.md, run by a firing and by their members' answers,
    each bounded by the line's members;
  * the Raspberry Pi 4's mini UART driver, run by its line, each delivery bounded by
    `?DRAIN_MAX` bytes (`erx_mini_uart.erl`), and by the console's output, which carries every
    session's output and the system log's lines and so is work an untrusted party asks for: the
    driver writes a byte only while the transmit FIFO has room and otherwise waits blocked, a
    millisecond at a time, so the output costs the urgent scheduler at most a register read and a
    write for each byte the line carries, about 11,520 a second at 115200 baud, and a message and
    its answer for each write the console forwards, which the console paces at the base level,
    one write of each session's in flight at a time within its facet's limit
    (`erx_console.erl`);
  * ERTS's own `erts_code_purger`, `erts_literal_area_collector` and the `high` one of its dirty
    process signal handlers (`erl_init.c:2546-2580`), run by a purge or a literal area's release
    that the runtime's own code loading asks for, and by a signal to a process running dirty code:
    the purger and the collector send each process a request and wait, and the scans those
    requests start run as system tasks on the processes' own normal schedulers, by the
    own-priority rule above;
  * `rpc`'s nodes observer (`rpc.erl:375-409`), which every runtime's `kernel` starts, run by a
    node's coming up or going down, each a domain's start or end, and by the peer's answer to its
    question, one message or one table update each, the answer's list read once;
  * `logger_olp`'s flush, which raises its process to `high` for at most its limit of messages
    (`logger_olp.erl:567-571`), in a runtime whose logger handler is built on it.

  A process that is not on its roster and runs on the urgent scheduler fails the urgent roster
  case, which watches what runs there under the release's client load and not only at boot
  ([Verification](#verification)); the load such a process carries to the urgent level is
  FD31's.

**The path of an interrupt.**

1. The line fires and Fiasco delivers it to the urgent scheduler it is bound to. A scheduler that
   was waiting takes its CPU from any thread but the watchdog, another urgent scheduler running
   there included, since a wake preempts its equals.
2. Its wait returns the label, the event table sends the driver's process its message, and the
   process, of priority `high`, runs on that scheduler, drains and acknowledges the device.
3. A scheduler that was running takes the delivery at its next safe point, at the end of the
   running process's slice of reductions or its garbage collection, with a wait whose deadline is
   zero; the driver's process then joins its queue behind the `high` processes queued before it.
4. What the driver hands on, a message to a `normal` process, goes to a normal scheduler's queue
   and wakes that scheduler at the base.

**What it bounds, and what it does not.** From the line's firing to the driver's process, a
scheduler that was waiting costs Fiasco's delivery and ERTS's dispatch; on the Raspberry Pi 4 the
kernel's path took under 10 us and a blocked thread ran within 3 us of its wake
([Bands](#bands), "The evidence"). The construction removes one delay: the wait of a thread that is
awake at the base for its turn there, with an ordinary process's slice of reductions and its
garbage collection, on any CPU. Ahead of the driver's process there can still be:

* the watchdog, and the urgent schedulers of other runtimes on the same CPU, each doing work its
  roster bounds;
* on its own scheduler, the running process to the end of its slice of reductions or of its
  garbage collection, then the `high` processes queued before the driver's, each to the end of a
  slice, as many as the roster's entries can have runnable at once;
* a lock the scheduler needs while a base-level thread holds it. A holder it preempted on its own
  CPU runs on to its unlock at once; a holder on another CPU that is itself off its CPU keeps the
  scheduler waiting for that holder's turn at the base, behind a slice of each base-level thread
  ahead of it there and every wake that goes in front, with no bound but that CPU's base-level
  load, since no holder is raised ([Scheduling](#scheduling), "Locks and priorities"). Run-queue
  locks, message-queue locks and the backend's locks are held for a few instructions; a process's
  main lock is held for its whole run, its garbage collection included (`erl_process.c:9458-9464`),
  and the urgent scheduler waits for one only where its process acts on another process in a way
  that takes that lock;
* a request the urgent scheduler makes of the root service, an allocator's new carrier first of
  all. The service serves one body at a time, so the request waits for the body it is running,
  at the base level when that body runs on the service's own context, and a caller that finds the
  service busy waits in its queue, where its time is lent to no one (`Thread::check_sender`,
  `thread-ipc.cpp:351-371`). While it waits, the scheduler takes no delivery. An app that floods
  the root with requests lengthens that wait (FD17);
* a `high` process's dirty work, and a garbage collection ERTS sends to a dirty scheduler, which
  run at the base.

No figure is promised: the bands and urgency give no bound on an interrupt's handling, and what
they give is measured against the 0.7 ms the Raspberry Pi 4's mini UART buffers, with each cell's
longest receipt recorded where a lock or a root request would show, and a cell that loads the root
service reported apart ([Verification](#verification)). A runtime whose `high` work does not end
still takes its CPU from everything below the urgent level (FD15).

**erXos's kernel has the same gap for a hint.** It loads an executor's published urgency only at
that executor's own transitions and never in a pick, and a trigger with no executor parked raises
no one, so an executor that is ready when its work turns urgent waits at the level it was queued
at ([design-scheduler.md](design-scheduler.md#urgency-resolution)): behind every thread ahead of
it at that level, a slice each, and behind any level above it, which may run without end there
(requirement 1 of [design-scheduler.md](design-scheduler.md#requirements)). The same construction
removes that stale-hint wait with calls that kernel already has, a worker whose base
`erx_thread_set_urgency` set and an IRQ object bound to it, and nothing more: the worker still runs
only while its group path can supply quota on its CPU (step 3 of
[Pick and dispatch](design-scheduler.md#pick-and-dispatch)) and nothing above its level is
ready, so it reserves no CPU. Whether ERTS then still publishes a hint is an open decision
([Open decisions](#open-decisions)).

**What was weighed.**

* *The thread raises itself.* An executor that sets its own level when it picks up `high` work
  cannot do so while it is ready and not running, which is the gap, and the call costs two kernel
  entries for each urgent episode and an operation and a bit in the fork.
* *The waker raises it.* The thread that signals an executor, a dispatcher or another scheduler,
  could raise it first. It needs a way to name a sibling thread in Fiasco, where no task holds a
  thread capability ([Who holds what](#who-holds-what)); it gives a thread's level two writers,
  the waker and the thread lowering itself, whose order decides whether a raise is lost; a
  dispatcher cannot know which executor's queue the driver's process is on; and the raised
  executor still finishes the ordinary process it was running, at the ceiling, before it reaches
  the urgent one.
* *The dispatcher drains the device.* A native drain of the device into a ring by the thread that
  takes the line keeps ERTS's scheduling as it is, where the urgent scheduler changes it at the
  places "Its place in ERTS" lists, but it removes the loss for that device alone, needs device
  code outside the driver for every such device, and leaves everything else the driver does, its
  line owner's round included, where it was. It stays what a
  native driver is: a measured row of the driver table, taken if the Pi measurement still loses
  bytes with the urgent scheduler in place.

**What it costs.** One thread in each ERTS runtime of the root and driver bands; the changes to
ERTS above, its enqueue, its five exclusions and its block; one request to the root at that
thread's start; a bind to a thread and a wait for it in the backend; a kernel entry and a thread
switch for each wake of the urgent scheduler by another scheduler; a kernel entry for each wait
whose deadline is zero, at least one at each of the urgent scheduler's process switches; and threads of one task at two priorities, which is why a backend
lock blocks ([Locks](#locks)). Nothing in the fork.

### Stages beyond bands

Each stage but the third is a contained change to the Fiasco fork, as CLAUDE.md allows for kernel objects and
scheduler hooks that integrate with Fiasco's C++, with the policy in erXos's C17 cores so it moves
into erXos's kernel. The sizes are estimates from the files named and are unverified.

| Stage | What it adds | Where in Fiasco | Estimate |
| --- | --- | --- | --- |
| 1, status words | each executor's state, CPU and preemption count written by Fiasco into a kernel-user page beside the UTCB, as Fiasco places a vCPU state area (`thread_object.cpp:578`) | the switch path (`Context::switch_sched` and `schedule`, `context.cpp:887-986`, of a 2,949-line file) | 150 to 300 lines of C++ |
| 2, deferred preemption | at a slice end with another thread ready, a bounded grace while the executor's `defer` count is raised; never for a higher-priority wake | `Timeslice_timeout::expired` (`timeslice_timeout.cpp:36-48`, a 49-line file) | 50 to 150 lines |
| 3, urgency within a band | the urgent scheduler: a thread at its band's ceiling that waits for the lines bound to it ([Urgency](#urgency)) | nothing in Fiasco: the root's `l4_scheduler_run_thread` and `l4_rcv_ep_bind_thread`, and ERTS's enqueue (`erl_process.c:6500-6553`) | none in the fork; 300 to 600 lines of ERTS |
| 4, group park | the group's ready list and epochs in the kernel, removing the dispatcher's thread switch | a new kernel object beside `Irq_sender` | 300 to 600 lines, with the park core |
| 5, group quotas | charging up the group tree across CPUs, as a new scheduling-context variant beside the fixed-priority one, which Kconfig's scheduler choice selects (`src/Kconfig:330-351`) | the fixed-priority variant is `sched_context-fixed_prio.cpp` (321 lines), `sched_context.cpp` (188) and `ready_queue_fp.cpp` (171); the six variant and queue files total 1,450 lines | 1,500 to 3,000 lines, with its policy in `kernel/sched/sched.c`, the C0 core |

Stage 3 changes nothing in the fork and is built when the Raspberry Pi 4's measurement shows a
loaded cell losing a byte ([Open decisions](#open-decisions)); its consumer is the driver of a
device whose buffer fills faster than a slice, the Raspberry Pi 4's console first, and the Pi
measurement of [Verification](#verification) is its test. The other stages follow the first release in the order
1, 2, 4, 5, once everything else works, each kept only when its measurement pays, as
[plan.md](plan.md)'s M8 keeps each feature of the ladder. Stage 4 is also what makes a park cheap
enough to spin before ([Scheduling](#scheduling), "A wait blocks"). Each stage that lands removes
its row's part of the downsides table.

### Consumers that name grants

No Phase 1b consumer needs a grant enforced to work. Those that name one get, on a release:

* [design-apps.md](design-apps.md) (a hostile app "can spend its session's budget and CPU grant"):
  its memory is held to the budget; its CPU to its band, CPU set and thread limit.
* [design-domains.md](design-domains.md): the hostile runtimes' bounds on CPU grants and on an innocent
  peer's latency report `unsupported` (FD15), and the band test of
  [Verification](#verification) checks what bands give.
* [design-network-stack.md](design-network-stack.md#the-fast-path): the network domain runs as many
  schedulers as its CPU set has CPUs, at most 32.
* [design-programs.md](design-programs.md) and [design-display.md](design-display.md): a program's
  copy and an application's drawing run on their own domain's threads, in its band.

## Security on Fiasco

### What a hostile app can do

An app is a domain whose code is untrusted. It holds its gate to the root, its threads'
semaphores, the doorbells of its connections, with trigger alone on its peers', and mappings of
its own memory and its connections' rings. With them it can:

* send the root any request: the decoder is the trust boundary, bounds every field and has its
  fuzz target; a value that names no live entry of its own table is `ERX_ESTALE`, and an entry of the wrong kind `ERX_ETYPE`;
* write anything into its own side of a ring: the receiving funnel checks every frame, as on
  erXos's kernel;
* trigger a peer's doorbell as often as it likes: a fire not yet received is one delivery
  (`irq.cpp:984`, [Interrupts and readiness](#interrupts-and-readiness)) and an object is listed
  once until a take, so the pending state stays bounded, but Fiasco clears the queued state as
  each delivery finishes (`Irq_sender::finish_send`, `irq.cpp:751-755`), so a ringer on another
  CPU makes the peer's dispatcher run, and wake a parked executor, once per delivery, at the
  peer's base level and never above it, since a doorbell a peer can ring is never bound to a thread above the base
  ([Urgency](#urgency), "What reaches the urgent level"), whether or not the peer has taken
  its readiness since (FD31);
* spend its own memory and kernel memory to their walls, and fail with `ERX_ENOMEM` there;
* spin every thread it may create, and every thread of its sub-spaces, at the app band's priority,
  which nothing it sends can change (FD15);
* flood its session, or a file, storage or network server it holds a grant of, which serve it at
  their own bands (FD31);
* send requests and take faults as fast as its threads can, which the root service serves on its
  own thread at the base level, or at the app level on the app's own remaining slice until the
  first thread above the app level wants that CPU ([Scheduling](#scheduling), "A call's slice"):
  the root's time spent on them is taken from the configured
  domains' ordinary work on the root's CPU, the drivers' included, which shares that level round
  robin, and from the app level there, and every other domain's setup and faults wait behind them
  (FD17);
* invoke every slot index of its object space with any arguments, and itself through the special
  selector, reaching only Fiasco's code for the objects placed there, for empty slots and for its
  own threads: this is the surface the fuzz campaign covers (FD24).

It cannot reach another domain's memory or objects without a defect in Fiasco or in the root's
decoder and placement code, create one mapping that is writable and executable (FD8 for two
mappings of one page), change any object
space or page table, bind or steal a peer's doorbell, set the wall clock, write the machine's
console except as escaped, attributed records, place a thread on a CPU outside its domain's CPU
set, make the root hold more
for it than its row's limits, or hold a device unless the manifest gives it one. On a CPU open to
branch-predictor injection it may read memory it cannot reach (FD32).

### The security closure

The security closure is the point from which a release build may run untrusted code. It has two
forms, one per kernel, and the first release reaches the first.

* **On Fiasco**, within [plan.md](plan.md)'s 0.2: M11's scope wherever it does not name erXos's
  kernel (the funnel and the services behind it, the vault, image hashes, packages, the host link,
  every user-mode fuzz target at full budget, the sanitizers on host builds, the external review),
  and in place of its kernel half: the release's Fiasco build of the next section; the system-call
  fuzz campaign at its full budget with no open finding; the hostile suites' Fiasco set below; the
  upstream watch current; the IOMMU confining every device the platform puts behind one, of which
  0.2's platforms have none, and each unconfined device in a domain of its own (FD12); FD32's entry
  patch carried or FD32 published, as the null-request bench decides; and this document's downsides published with
  the release.
* **On erXos's kernel**, M11 as written: every hostile suite in full and every guarantee of
  [design-kernel.md](design-kernel.md).

The hostile suites are written against the interface, so one suite runs on both kernels. A case
that checks what Fiasco lacks reports `unsupported` there, and its row below names the downside.

| Hostile case | Fiasco | erXos's kernel |
| --- | --- | --- |
| frames at every funnel: verdicts, forged senders and names | runs | runs |
| reach into another domain's memory or objects | runs | runs |
| a destroyed object's handle in every holder | runs: `ERX_ESTALE` | runs |
| a handle used after its own close | runs: `ERX_ESTALE` from every service call; a ring or an acknowledgement through a closed IRQ handle reaches the object its entry holds next (FD1) | runs: `ERX_ESTALE` |
| rights only shrink across duplicates and passes; a ringer cannot bind | runs | runs |
| memory and kernel-memory walls, a neighbour unaffected | runs, filling the domain's factory, its pages and its share of the root's tables, without borrowing or returns (FD25) | runs, with borrowing and returns |
| the wall clock set by an app | runs: `ERX_ERIGHTS` | runs |
| a pause of a space whose threads block, fault or repoint their exception handler | runs | runs |
| a flood of a service against that service's band | `unsupported` (FD31) | runs |
| branch-predictor training against the kernel and other domains | `unsupported` (FD32) | runs |
| doorbell floods | runs: the pending state stays one listed entry; the holder's deliveries and wakes per take are measured and reported, not bounded (FD31) | runs |
| sub-space churn | runs | runs |
| a spinning domain against a higher band's latency | runs | runs as the grant test |
| a request and fault flood against a neighbour's setup and latency | `unsupported` (FD17) | runs |
| CPU grants and an innocent peer's latency within one band | `unsupported` (FD15) | runs |
| stops and exit records under hostile load | `unsupported` (FD20) | runs |
| DMA outside a device's window | runs where the IOMMU covers the device (FD12) | runs where the platform has an IOMMU |
| the kernel's own call surface fuzzed | Fiasco's invocations (FD24) | erXos's dispatch |

## Ownership and authority

Everything above `liberx` calls the generated functions. Each has one stub, in every image, the
root's included. The stub runs locally, for calls that never need the kernel, or sends a request to
the [root service](#the-root-service), which runs the call's body.

### Capabilities in Fiasco's object space

The root holds a capability to every object it creates, with Fiasco's delete right, so
`l4_task_delete_obj` always reaches it. Callers hold **handles**, entries of their tables in the
root ([Handles](#handles)). A handle's value carries the entry's number and generation, and the
service's one lookup checks bounds, the entry in use, the generation, the object's liveness, its
kind and the holder's rights on every request. So a handle to an object that has gone, a handle
used after its own close and a forged value each answer `ERX_ESTALE`, as on erXos's kernel. Thread
handles are the exception that [Thread creation](#thread-creation) describes.

Each thread of a task has a pair of the root's slots, for itself and its semaphore, and each task two
pairs, for its gate, its space and the semaphore its end ups, all from the root's slot pool
([Handles](#handles)). Of these, the task itself holds its gate and its
semaphores, at the rights [Who holds what](#who-holds-what) gives them. It also holds the IRQ
objects its handles name, at their IRQ slots, with `L4_CAP_FPAGE_RO` alone. The root maps each of
these into the task with `l4_task_map`:

| Slot | Object | Used for |
| --- | --- | --- |
| `L4_BASE_PAGER_CAP` | the task's gate | `_pager` and `_exc_handler` of its threads, resolved in the thread's own task at the fault (`thread-ipc.cpp:254,1020`), and every request |
| the first slot after `L4_BASE_CAPS_LAST`, plus the thread's index | the thread's semaphore | umtx, park, reaper |
| the IRQ base ([Handles](#handles)) plus an entry's index | the IRQ object that entry names, while the entry is open | `erx_irq_trigger`, `erx_irq_ack` |

The time page, status pages and boot information page are mappings, not capabilities.

### Helper threads

Each is backend C with no thread-local storage, and calls no musl function.

| Thread | Runs in | Does | Phase 1 consumer |
| --- | --- | --- | --- |
| root service | root | owns the root's tables; serves requests, page faults and exceptions | every call and crash record |
| watchdog | root | steps `watchdog.c` over the pet word | M1's criteria |
| reaper | each task, one, its runtime's | deletes exited threads ([Deletion](#deletion)) | `pthread_join`, detached threads |
| dispatcher | each task, one, its runtime's | turns the deliveries of the objects bound to the task's groups, doorbells and lines alike, into triggers, at its band's base | lanes, channels, pipes, ERTS's wakes, a line no thread takes |

A task's own threads create its reaper and its dispatcher, at backend initialisation, through the
ordinary calls; the dispatcher's creation registers it with the service, which takes one a task
(`group.c:136-137`). Both live in the image's own data (`thread.c:81-88`, `park.c:45-51`), so a space runs one
image's backend: the loader `erx_exec` does its work before backend initialisation and starts neither, and the
executable it enters starts the task's only pair ([Thread creation](#thread-creation), "An exec's entry"). The root's dispatcher starts with the
root's first group instead, as that group's first thread ([Budgets and groups as records](#budgets-and-groups-as-records))
([Interrupts and readiness](#interrupts-and-readiness)). The watchdog, like the root service, holds no thread index and
takes a free slot of the kernel-given UTCB page, with `sigma0` as its pager. `moe`, L4Re's root task, is likewise one server thread for
memory and faults (upstream; `moe` is not in this tree), and `libpthread` serializes thread and UTCB
work through one manager thread (`manager.cc:494`). The cost is that the machine's memory, thread
and log calls queue on one thread, which Phase 1 accepts and an ERTS boot measures.

### Locks

A backend lock is one word and one Fiasco semaphore, and a thread that finds it held blocks on the
semaphore, so the lock is safe between threads of any two priorities on any CPUs
([Scheduling](#scheduling), "Locks and priorities"). The word counts the holder and the threads
waiting for the lock, so 0 is free, 1 is held, and every unit past 1 is a thread that has
committed to a down:

* **Lock.** The thread adds 1 to the word. If the word was 0 the thread holds the lock, with no
  Fiasco call. Otherwise it downs the semaphore with no deadline, and when the down returns it holds
  the lock, which the unlock handed it.
* **Unlock.** The holder subtracts 1 from the word. If the word was more than 1 a thread is waiting
  or about to, and the holder ups the semaphore once, which hands the lock to one of them.

Every up matches one addition that found the lock held, so the semaphore never holds more credits
than there are threads between their addition and their down, and a credit waits only for the
thread that is on its way to take it. Each unlock makes at most one holder, which is mutual
exclusion, and no credit outlives the waiter it was made for, so a waiter never loops: its one
down either blocks or takes the credit made for it. Fiasco's semaphore makes this exact. An up with
a thread queued hands it that thread and stores no credit, and otherwise stores one
(`Semaphore::count_up`, `semaphore.cpp:48-67`); its queue is ordered by priority
(`Locked_prio_list`, `semaphore.cpp:22`; `sender_enqueue`, `:176`), so an unlock hands the lock to
the most urgent waiter, the one at the ceiling before one at the base. A down that the root's pause
cancelled ([Threads, bands and stops](#threads-bands-and-stops)) either left the queue and took
nothing (`semaphore.cpp:262-271`) or, when the up raced the cancel, reports success
(`semaphore.cpp:274-291`), so the stub's retry of a cancelled down neither loses nor doubles a
credit. The word never exceeds the number of threads that take the lock, which the task's thread
limit bounds, so it cannot wrap.

The lock is handed over rather than taken: between the unlock and the woken waiter's first
instruction the lock is held by a thread that is not yet running, and a thread that arrives then
waits behind it. That costs a held lock the waiter's wake, which preempts its equals on its CPU,
and buys a lock that no waiter spins on. The root makes a lock's semaphore with what the lock
belongs to, a task's three with the task, at fixed slots of its object space and charged to it as
its threads' semaphores are, and the root's own at its start.

No lock is held across a Fiasco call or a request, and no thread holds two. A wake or
`l4_semaphore_up` of another object follows the unlock.

| Lock | Scope | Guards |
| --- | --- | --- |
| thread lock | one per task | the records' free states, the reaper's list |
| umtx lock | one per task | the umtx table |
| park lock | one per group | a group's epochs, parked list, ready list |
| trace lock | root | the trace ring's writes; its reader takes none ([The trace ring](#the-trace-ring)) |
| mailbox lock | root | the mailbox core's state, for one step of a firmware request or of the trial request, never across a sleep ([The firmware request](#the-firmware-request)) |

The service takes only the trace lock, and the mailbox lock for the trial request's steps, each for
a holder's few instructions, and otherwise waits only on Fiasco's calls and `sigma0`.

### The chokepoint

Fiasco's headers and capability values appear only under `liberx/backend/fiasco`. Within it, the
Fiasco calls that charge a task's quota, `l4_task_map`, every `l4_factory_create` form and
`l4_task_add_ku_mem`, appear only in `charge.c` (the `fiasco-charge` rule), so the module that turns
each refusal into `ERX_ENOMEM` and the undo of its call is the only route to one
([The construction](#the-construction)). Each is a build check that fails on a new site, and each
has a seeded violation.

### Interfaces

erXos's C17 code reaches Fiasco's kernel through one seam. Inside the kernel, the cores Fiasco links
(`erx_cores.a`, the policy of its patches among them) are called only from the glue under
`fiasco/kernel/src/erx/` (`erx_handoff.cpp`), and what the glue may reference of Fiasco is one
allowlist, `fiasco/erx_glue_imports.txt`: a line per symbol, with the effect that needs it and the
glue file that may hold the reference. Every source in that directory is glue and is built, and the
build check `tools/lib/erx/glue_imports.rb` fails a glue object with an undefined symbol its file
does not list, so a new path into Fiasco, a raw allocator among them, cannot be reached by adding a
call; the cores' own `erx_` functions need no entry. The kernel stack proof and the kernel-side
chokepoints check the cores. Above the kernel, the seam is the function API of
[Ownership and authority](#ownership-and-authority) and the chokepoint above.

## Boot handoff

**Bootstrap.** `bootstrap` is the first stage of the bootable file
([design-kernel.md](design-kernel.md#the-bootable-file)). `startup()` calls `erx_image_load`
(`erx_image.cc`), which applies one pure plan, `erx_boot_load_plan` (`kernel/core/boot_place.c`).
Inherited code reads no executable and no modules.

1. The plan finds the archive through the locator in the bootable file's header, or as the one
   initrd, opens it with `erx_pack_open`, and checks each role's file with `erx_pack_file_check`:
   the kernel, `sigma0` and the root, at the ABI's `boot_kernel_path`, `boot_sigma0_path` and
   `boot_stand_in_root_path`.
2. It reads each with `erx_elf_plan_kernel` and places them. The root, a static executable, runs
   at the physical addresses it is linked at, which must lie in memory and clear `bootstrap`, the
   device tree and every reserved region. The archive stays where the loader left it unless such
   an image lands on it, and then moves, whole, to the lowest free page behind those images, as
   stock Fiasco's `bootstrap` moves its modules (`Boot_modules::move_modules`,
   `boot_modules.cc:262`). An image that relocates itself, as the fork's kernel and `sigma0` do,
   goes behind the archive, and a kernel that cannot relocate fails the plan. The device tree's
   copy and the handoff page each take the lowest free page in memory past the first, so neither
   is at address 0, clear of everything placed and of the archive where the loader left it, since
   both are written before the archive moves; the archive's new place may overlap its old one. A refusal prints `erXos image: <where>: <reason>` and stops, having copied and moved
   nothing (`archive_no_room`, `device tree: no_free_ram`, `handoff page: no_free_page` among the
   reasons).
3. Every check and reservation comes before any byte moves: `erx_image_load` checks the kernel
   information page's magic and the options block's magic and version where the copy will read
   them, reserves the whole archive at its final place, never released, then the images, then
   writes the device tree's copy and the handoff record. Only then does it move the archive, if
   the plan moves it, as `memmove` does, and copy the images from the archive's new place; nothing past that point
   refuses. Each range it writes is cleaned from the data cache by whole lines. A `Region::Root`
   region's sub-type is what `sigma0` answers a page fault of the root with (`init_mem.cc:73`,
   `memmap.cc:170-176`): `Root_section_rwx` for the root's image, whose segments one range cannot
   tell apart, and `Root_section_rx` for the archive, read and execute and never write, so the
   root can map an image entry's code from the archive's own pages.
4. `erx_boot_handoff_write` writes the `erx_boot_handoff` record of `abi/kernel.txt`: flags, build
   identifier, index hash, the archive's range, `/chosen/bootargs` cut at the last whole word, the
   full path of the node `/chosen/stdout-path` names (libfdt resolves the value up to its first `:`,
   a path or an alias of `/aliases`; empty when that names no node or is longer
   than `ERX_BOOT_STDOUT_PATH_MAX`), the boot value with its slot, which `erx_boot_pair_derive`
   computes from `/chosen/bootloader`'s `partition` and `tryboot`
   ([design-platforms.md](design-platforms.md#data-model)), `unknown` with slot `none` when either
   is missing or malformed or the partition is not a slot; the range of the device tree's packed
   copy, without `/chosen`'s `linux,initrd-start` and `linux,initrd-end`, reserved read-only as
   `.erxtree`, the boot refused when it exceeds `ERX_BOOT_TREE_MAX`
   ([design-device-tree.md](design-device-tree.md#on-fiasco)); and the boot CPU's identification
   registers, which user mode cannot read and Fiasco publishes nowhere, in the record's `cpu_id`
   words. It writes the record into a buffer of its own before anything moves, and into the
   **handoff page**, reserved read-only for the root, and copies it into the options block for the
   kernel once the kernel is copied; the options block is mapped into no task, so the root reads the
   handoff page. The record's pool fields stay zero, with no reader.
5. `init_kip_infos` assigns the page's address to the kernel information page's `user_ptr`
   (`init_kip.cc:30`).

**The kernel.** Its options are a constant, `Fiasco::KERNEL_OPTIONS` (`fiasco.rb`), built into
`bootstrap`, with neither `-serial_esc` nor `-serial_input`. Its configuration is one defconfig,
`config/fiasco/kernel.defconfig`, for every board. A development kernel is built from it as it is,
with JDB, the kernel debugger, and the kernel's own console input it selects: a panic enters JDB on
the console, or before JDB is initialized waits for a key, so the run waits for the operator or the
harness's deadline. A release kernel is built from the same defconfig with `CONFIG_JDB` and
`CONFIG_INPUT` unset, its only differences, stated once in `FiascoConfig::RELEASE_UNSET`
(`fiasco_config.rb`). A kernel trap is fatal in both: a development kernel enters JDB, stopping
every CPU, and a release kernel prints the trap state and panics
(`Thread::call_nested_trap_handler`, `arm/thread-jdb.cpp`), so no faulting CPU traps again while
the others run. A kernel-mode SError is counted and execution goes on, in both
(`Thread::arm_serror_handler`, FD33). Without console input a panic resets at once
(`terminate.cpp`, `Exit_question::ask`, and `raw_exit` before `kernel_main`) through PSCI's
system reset, or the BCM2711 watchdog where the device tree has one and no PSCI was found
(`reset-arm-gen.cpp`), and otherwise loops forever: a panic before `Dt::init` and `Psci::init`,
the handoff checks among them, does not reset. With console input in, the exit question would wait on the console with
interrupts off instead. `FiascoConfig` checks the resolved configuration,
`globalconfig.out`, after every configuration step, since a `select` can set what the defconfig
leaves unset: every kernel needs `CONFIG_FPU`, `CONFIG_PERFORMANCE`, `CONFIG_PERF_CNT_USER` (with
`CONFIG_PERF_CNT`, which only JDB turns on by default) and
`CONFIG_SYNC_CLOCK`, and none has `CONFIG_LAZY_FPU`, `CONFIG_ARM_SVE` or `CONFIG_CPU_VIRT`.

A release kernel links only sources a release build may carry: its build runs the link audit
(`FiascoProvenance`) over the kernel and fails naming each linked source whose license, as its
import record or toolchain registration gives it, the one rule of
[design.md](design.md#licenses-and-notices) (`LicenseCheck`) does not accept in a release
build, the rule the image check applies. It accepts a permissive license anywhere and nothing
beyond it ([License](#the-releases-fiasco-build)), so `jdb_object.cpp` (GPL-2.0-only), whose row of the
closed table accepts it in development builds only, is built only with `CONFIG_JDB`, into
development kernels, the published images' included; a source the audit cannot attribute fails
the build too, and a file without a license passes only as configuration or as one made from
attributed sources. The audit rests on the
release build's own compile records, the import records' licenses and the profile's account of
each generated kernel file, not on a development build's pinned generated bytes or host tools: a
development build's audit records each generated file that the host's tools made with other bytes
in its report's `host_generated` instead of refusing the build, and the image stays project-only.
A refused kernel is removed; one that passes has `license-check.json` beside it, naming its build
kind and its bytes.

The kernel's own changes are `erx_handoff.cpp`: it accepts the record, refusing a boot value and
slot that are not one of the machine page's pairs, prints the banner (`development build: trusted
code only`, the build identifier, the index hash, then `erx: boot value <unknown|normal|trial> slot
<none|a|b>`, from a fixed table) and panics if no bootloader descriptor covers the archive. The
kernel greets as erXos (`kip.cpp`) and starts `sigma0` and then the root (`std_workload.cpp`), with
capabilities at `L4_BASE_TASK_CAP`, `L4_BASE_FACTORY_CAP`, `L4_BASE_THREAD_CAP`, `L4_BASE_PAGER_CAP`
(a gate to `sigma0`), `L4_BASE_LOG_CAP`, `L4_BASE_ICU_CAP` (also the platform control object) and
`L4_BASE_SCHEDULER_CAP`; a stack pointer of 0; one page of UTCB slots (`std_workload.cpp:95`);
Fiasco's default priority, on the boot CPU.

**The root's first steps, in order.** Only the first thread exists until step 7, so it runs the
service's bodies directly.

1. Sets its stack, inside its image. Touching it faults to `sigma0`, which maps it one to one.
2. Maps the kernel information page with `l4sigma0_map_kip`, reads the handoff page at `user_ptr`
   through a page fault, and accepts the record with `erx_boot_handoff_accept`, which checks the device
   tree's range among the rest; it reads the tree's pages through page faults too, so they are mapped
   read-only.
3. Maps its whole image at its physical addresses with `l4sigma0_map_mem`, and touches each page of
   the archive, so the fault path maps it read and execute by its sub-type: `l4sigma0_map_mem` is `sigma0`'s
   RAM request, which maps read, write and execute whatever the sub-type says (`memmap.cc:125`). After
   this step no page of the root is mapped on demand.
4. Finds the archive's `system_manifest_path` entry, checks its file hash and reads it through the
   generated C reader, which allocates nothing and whose view stays in the archive, and reads the kernel
   command line from the handoff view's `bootargs` ([The command line](#the-command-line)). Later steps
   take device entries and the system's arguments from the first, and the watchdog's
   numbers and deterministic mode from the second. Accepts the device tree with `erx_dt_accept`, refusing
   the boot on its reason, reads `/chosen`'s `rng-seed` and `kaslr-seed` from it for step 6 (the root's
   read-only copy of the tree keeps them: a residual in `TODO.md`), and stores
   each device row's facts from it in the row's catalogue entry
   ([design-device-tree.md](design-device-tree.md#facts-into-records)).
5. Builds the contiguous pool, sized for the devices' memory the manifest declares, and the pool window
   ([The pool](#the-pool)). If the pool and the root's
   image together hold less than the manifest's `root_memory`, it refuses the boot.
6. Makes its own thread table ([Thread creation](#thread-creation)); seeds `rng.c` from the counter and
   step 4's seeds (`erx_rng_seed`), and on the Raspberry Pi 4 from its RNG200 when
   [Entropy sources](design-platforms.md#entropy-sources) calls for it ([The Raspberry Pi 4](#the-raspberry-pi-4)); prints
   the entropy line, and in a release, with fewer than 32 bytes from sources other than the counter, the refusal of the
   `erx_entropy_read` row ([the call table](#the-call-table)), and ends the machine as `ERX_END_OFF`, so no domain starts
   on the counter alone; makes its object
   tables, then fills the time page, a pool page recorded as a memory object and kept until the
   machine ends ([the call table](#the-call-table)); creates its gate, the service
   thread, stopped, with the `sigma0` gate as pager, and the watchdog with its configuration and start
   event (`watchdog.c:127`).
7. Points its own `_pager` and `_exc_handler` at its gate and runs the service and the watchdog,
   then erases its own copy of step 4's seeds.
   **From here the service alone touches the root's tables.**
8. Checks that the manifest's `console` is the node path the handoff view's `stdout_path` carries,
   the device service's check at boot ([design-system.md](design-system.md#devices)), which the root
   makes while no device service runs, and otherwise refuses the boot with both paths
   (`erx_boot_console_matches` in `liberx/backend/core/boot_manifest.c`). Creates its reaper, fills
   the boot information page (`runtime_entry.c`), moves off the image's small
   stack and enters musl's start path, whose `main` (`runtime_main.c`) calls `sys/erxos`'s `erx_runtime_main`.
   ERTS reads the boot information page, so the one `argv` word in musl's start block goes unused.

A failure in steps 1 to 6, or of step 8's console check, prints its reason through `l4_vcon_write` and ends the machine, with no
crash record.

### Boot information

The ABI's `erx_boot_info` layout is kept. One pure function,
`erx_boot_info_build(inputs, page, size)` in `liberx/backend/core/`, writes the page and returns a
reason on refusal, with checked arithmetic on every offset. Each entry only gathers its inputs, and
`erx_boot_info` then returns the same fields on both backends, validated by the same reader:

| Field | The native root | The hosted entry |
| --- | --- | --- |
| `version`, `abi_version`, `domain_id`, `seal_addr` | 1, `ERX_ABI_VERSION`, 4, 0 | the same |
| `flags` | `ERX_BOOT_ROOT`, with `ERX_BOOT_DET` under `erx.det=1` and `ERX_BOOT_DEVSYNC` under `erx.devsync=1` | `ERX_BOOT_ROOT` |
| `pack_flags`, `release_addr` | the handoff's flags; its archive start, which `sigma0` maps one to one | the archive header's flags; the address of its `mmap` |
| `group` | what `erx_group_create` returned | `ERX_CAP_SELF`, which a bind accepts |
| `time_page` | a handle to the time page's object ([the call table](#the-call-table)), which the domain library passes to each domain; the root's own reads find the page with no handle | `ERX_CAP_NULL`: the hosted clock is the host's |
| `space` | `ERX_CAP_SELF`, as every space names itself | the same |
| `budget`, `group_ctl`, `group_stat`, `spaces_group`, `release`, `crash_area`, `system_connection` | `ERX_CAP_NULL` and zeros: `erx_vm_*` and `erx_group_status` find theirs with no handle, `erx_release_entry` reads the archive, and no Phase 1 caller takes the rest | the same |
| `cpuset`, `capacity_mcpu` | the manifest's system share's `cpuset` within what `l4_scheduler_info` reports; 1,000 for each CPU, since Phase 1 has no grants | the host's online CPUs; the same |
| `urgency_base`, `urgency_ceiling` | the base and the ceiling of the system share's grant; a domain's page carries its own group's, and on this backend the domain library writes the base in both for a domain whose band has no level above its base, so a runtime starts an urgent scheduler only where one can run above the base ([Urgency](#urgency)) | the grant's base in both: the hosted backend has one level |
| node name | `system@` and the manifest's `host` | the same |
| `args` | the manifest's `system_args`, the console's words, `-erx_record boot VALUE SLOT` ([the booted slot](#the-booted-slot)), `-erx_record build ID`, the boot image's build identifier in decimal, and each [device record](#device-records), then each `erx.arg=WORD` | the manifest's `system_args`, then `-erx_record console stdio`, then the command line after the archive's path |
| `env` | empty | empty: the host's environment is not inherited, and the entry sets `TZ=UTC` for libSystem |
| `hwcap`, `hwcap2` | the features the boot CPU's identification registers name that the kernel enables and saves for user mode, from the handoff's `cpu_id` words ([Boot handoff](#boot-handoff), step 4; the architecture's binding gives the mapping, [design-arch-aarch64.md](design-arch-aarch64.md#cpu-feature-words)) | 0, which claims no optional feature |
| `limits` | the projection of the manifest's `system_runtime_limits` | the same |

`system_args` is a new string of the manifest's header, under the same rule as a domain's `args`, so
the system's start has the one configuration file every other setting has. It holds what `erl_start`
reads, emulator flags, `--`, then `init`'s arguments, with nothing converted on the way
([Configuration](design-runtime.md#configuration)), so what follows it on the page, the driver's name and
the command line's words, are `init`'s arguments. Strings past `ERX_BOOT_STRINGS_MAX` (2,048), or a limits record out of range,
refuses the boot with the reason, as in step 6's failure; ERTS never starts on a
partial page.

Every record a writer adds to a page's arguments, the console's, each device's, the boot's pair, the
build and the hosted console driver, opens with one flag, `-erx_record`, whose name is the ABI's
`boot_record_flag` (`abi/erx_abi.txt`), generated into C (`ERX_BOOT_RECORD_FLAG`, `include/erx/boot_words.h`),
Erlang and Ruby. The flag names no application: OTP's application controller reads each flag named after an
application as that application's environment, every word a term
(`otp/lib/kernel/src/application_controller.erl`, `get_cmd_env`), and a record's PATH is not one. So no record
word becomes environment, and init hands the records, as words, only to `erx_device_record:records/0`,
which every record's parser reads. No record word becomes an atom: the console maps the peripheral
`-erx_record console` names to its driver and refuses any other, and the readers of the other
records match their words against names of their own. A test holds every application's
name apart from the flag's.

A reader, `erx_boot_info_read(page, size, view)`, checks the version, the ABI version, the flags, the
reserved words and every string against the page and `ERX_BOOT_STRINGS_MAX`, and `sys/erxos`'s
`erx_runtime_main` starts ERTS on nothing else. `erx_boot_argv_plan` and `erx_boot_argv_fill` make
[the vector for `erl_start`](design-runtime.md#configuration) from what it accepted, led by the flags of its ERTS limits
([Starting a runtime](design-runtime.md#starting-a-runtime)), and `erx_boot_erts_admit` holds
ERTS's parsed settings to them. A word list on
the page has no empty word, and an environment word is `KEY=VALUE`. Both the build and the read refuse
anything else with its reason, and a refused build writes nothing.

The page is a page of the root's image, written before any other thread reads it and not read-only:
Phase 1 keeps no isolation inside a task. The launcher writes a test task's page with the same
function and maps it read-only.

**A domain task's page** is the domain library's, built by the same function from what
[Creating a domain](design-system.md#creating-a-domain) gives it, mapped read-only, and passed to the
task's first thread as its argument. Its `flags` carry `ERX_BOOT_DET` when the system's page does. Its strings hold the
domain's node name and the system node's, its `args` and `env`, and the words the library adds to its `args`, after
the row's own: `-erx_record build ID` with the boot image's build identifier, as the root's own page carries it, so
every domain names the same build; one `given` record per device it was given that has one, the
same record the root writes into the system domain's page for each device of a kind it holds
([Device records](#device-records)), or, for a framebuffer the root placed, `-erx_record framebuffer WINDOW_H OFFSET SIZE WIDTH HEIGHT STRIDE FORMAT` ([design-device-tree.md](design-device-tree.md#facts-into-records)), and, when it holds a
block device, `-erx_record boot VALUE SLOT` with the boot's pair, as the root's own page carries it, and, when the
manifest's `system` window row names it, `-erx_record system_image` ([The booted
slot](#the-booted-slot)). A device of no kind has no record and no window of its own: its registers on a page that a device of a kind in
its unit shares lie in that device's window, and a line it shares with one is that device's IRQ object
([design-shared-devices.md](design-shared-devices.md#the-unit-rule)). The
domain library's boot view admits a configured row or a session template only when its own words leave room within
`ERX_BOOT_STRINGS_MAX` for all of those at their longest (`ERX_DOM_NODE_MAX` per node name, and the record sizes of
`include/erx/boot_words.h`), and refuses the manifest with a reason naming that reserve otherwise, so a creation never
fails on its strings and the manifest check refuses such a row at build time. A session template's reserve
also holds the word the library adds to the environment of every session a start row or a `onestart` starts,
`ERX_START_FLAGS=` with `start_flags_max` bytes of start flags and its NUL
([design-apps.md](design-apps.md#start-flags)), in the same check (`boot_strings_fit`); and the view refuses a
session template whose own environment sets `ERX_START_FLAGS`, as it refuses a display domain's row that sets a key
of its display record, so the value a session reads is its row's alone. The domain runtime image's
entry, `domain_entry.c`, copies the page into its own memory and reads the copy with the same reader
before musl's start runs, so every later read sees the page it checked; a page the reader refuses, or an argument that names no page, ends the task with the reason on the
console and the status `ERX_FIASCO_TASK_STATUS_BOOT_PAGE` (-4), which the library's fault gate
reports as a HALT; no runtime code reads a refused page. Five fields are read differently from
erXos's kernel:

| Field | On this backend |
| --- | --- |
| `group_ctl`, `group_stat` | `ERX_CAP_NULL`. A group's status page is part of its home task's park record ([Interrupts and readiness](#interrupts-and-readiness)), and `erx_group_status` returns the page of the calling thread's group from that record |
| `time_page` | a handle to the time page's object, passed from the root's own; the task's `liberx` does not map it, since the service mapped the page at the task's creation |
| `release` | a handle to the domain's release slice, which `erx_release_entry` names in its request ([the call table](#the-call-table)) |
| `release_addr` | where the domain library mapped that slice; a file's offset counts from it, and `erx_release_addr` returns it |

The release's files are not checked one by one: the root checks the index and the last entry
(`root_open.c`), and the hosted entry's `erx_pack_open` checks the index, so a read stays in bounds
whatever a file holds. erXos's kernel checks each file at its first slice.

### The command line

`/chosen/bootargs` reaches the root through `erx_boot_handoff_view_t`'s `bootargs` and `bootargs_len`.
`erx_boot_args_parse(bytes, length, out)` in `liberx/backend/fiasco/boot_args.c`, a pure function with a
fuzz target, splits it on spaces and reads six kinds of word: `erx.watchdog=P,D,B`, through the
existing `erx_watchdog_parse`; `erx.det=1`; `erx.devsync=1`; `erx.group_report=1`; `erx.hostlink=1`; and `erx.arg=WORD`, at most as many as fit the page's
strings. Other words are ignored, as a boot loader's may be there. A release build refuses the boot on `erx.det=1` or `erx.devsync=1` with a
fixed reason, as erXos's kernel does ([design-kernel.md](design-kernel.md#configuration)). A malformed `erx.` word, and an `erx.` word of no known kind, refuses the
boot with a fixed reason. Bootstrap cuts the record at the last whole word, so a parser never sees half
a word.

`erx.group_report=1` is the native form of the hosted backend's `ERX_HOSTED_GROUP_REPORT`. Once the
system's group exists, `liberx/backend/fiasco/park_report.c` starts a worker thread of the root that
looks at the group's status page ten times a second and logs `erx: root task: group: parked N of M`
as a debug log record of the root's space each time the count of parked executors or of executors
changes, as the root's standard output is logged ([the console](#the-console)). The thread only
reads the page, logs and sleeps. Both backends' reporters build the line with `erx_group_report_line`
(`liberx/backend/core/group_report.h`), each under its own head; it is fixed words and two numbers,
and once the log service holds the log, the console writes the record whole between its other writes. The production image suite boots with it and waits for `parked N of N`, N the
system's schedulers and dirty CPU schedulers, after the shell's banner and a line typed at the prompt
that keeps one scheduler busy for half a second, so the report must show it wake and park again: M3's
idle machine.

`erx.hostlink=1` asks for the host link: only with it does the root hand the system domain's ERTS the
host link's device record ([Device records](#device-records)). The manifest names the host link's UART
by its device-tree path, and the root does not look in the device tree for it, so on a machine without
that UART the record would point `erx_pl011` at empty address space, whose first read faults the
system domain and with it the machine. Without the record no line group starts `erx_hostlink` and the boot
is the same otherwise. `Erx::QemuPlan` adds the word exactly when it gives the guest the second
`-serial` ([The production image](#the-production-image), "Device paths"), and the card writer puts it in `cmdline.txt`
on a development card whose platform names a host link UART; the website's emulator, whose machine has one UART, never
sends it. erXos's kernel needs no such word: it lists a UART only when the device tree has it.

## The Phase 1 manifest check

`Pack#build` packs only the manifest bytes `Manifest.admit` returns
(`manifest.rb`), so no image `Pack#build` publishes carries a manifest that has
not passed the check.
**`Check`** is that one check, and test fixtures go through it too: a
development manifest, full or partial boot, with the system domain and its
configured domains. It accepts the records the system
release's services and the configured domains need, `domain`, `window`,
`service`, `facet` and `introduce` among them, and refuses
`partial_boot` and `liveness` records with a diagnostic naming the milestone
that brings them. It accepts a `facet` that names operations only of a message
service the system domain serves, whose `erx_facet` checks them through its
callback ([design-time.md](design-time.md#on-fiasco)): a mint in a configured
domain and an `erx_fs` grant check none, so such a facet would grant the whole
service, and the domain library's boot view refuses one too. A
facet's parameters it resolves as [design-abi.md](design-abi.md) says, each
key against its service's declaration and each value against that key's kind
and bound, and the manifest property that consumes them holds as written, as
property 18 does for `windows`. Every release the production image
starts lies in its boot image, which holds what the rule of
[design-storage.md](design-storage.md#data-model) allows it, and the
slot's system partition holds the image builder's packages.
QEMU `virt`'s record is
[config/platforms/qemu-virt.json](../config/platforms/qemu-virt.json) and its
development manifest is the records every board takes,
[config/manifest/development.txt](../config/manifest/development.txt),
followed by its own part,
[config/manifest/qemu-virt-development.txt](../config/manifest/qemu-virt-development.txt)
(`Platform#manifest_source`), and the manifest check takes the two as one text;
the website's image has a manifest of its own, made from the development one
whenever it is needed and never checked in (`Platform#site_manifest_source`): the
development manifest without the configured domains the platform record's
`site_leaves_out` names and without its `apps` row
([design-packaging.md](design-packaging.md#the-apps-row)), each taken out with
the room it took, which the same check accepts. The image states the boot timeout
of the website's machine, 600 s (`ProductionImage::Machine.site`), since
the emulator boots its domains several times slower than the 60 s default allows
([design-system.md](design-system.md#the-manifest)). On QEMU `virt` those domains are
the web domain, since the website's page has no host link and the web facet is
all that domain serves, the display domain, since the page has no gpu for it
to drive, and the PCIe domain, since nothing on the page uses a PCIe function;
each would only cost boot time on the emulator's one core.
`Manifest::Edit.without_domain` takes a domain out as if it had never been written
in: its record, the units it holds, the services it serves with their display
records and the system domain's facets of them, the facets that grant it a
service the system domain serves, and the limits, share and
runtime limits only it names; it gives the room back where the manifest reckons
it (the principal's memory and domain quota, and the machine's `root_memory`,
including the domain's units' DMA memory, `max_domains` and `max_connections`), so
the result keeps the development manifest's margin and gains no record, grant or
authority it lacks. A domain whose service another domain or another principal's
template is granted, that is granted a service another domain serves, or whose
removal would leave a record naming one it took, is refused, since what such a
grant takes is reckoned only in the manifest's comments. The room given up stays
outside the root's memory; no domain gains it, and the 300 mcpu the three shares
took, with what the reserve leaves beside the configured domains' grants, is what
the system share's reserve leaves free for the
medium boots' test rows (`MediumBoot::EIGHTH_SHARE`).
Its scope, against
[design-system.md](design-system.md)'s properties, each kept property with a
seeded violation and each refusal with a seeded record:

| Property | Phase 1 | Whole again at |
| --- | --- | --- |
| 1 one holder per device and unit | kept; a holder is the system domain or a configured domain | |
| 2 facets name servers | kept, with introductions: a facet names a service of the manifest, served by the system domain or a configured domain, and is granted to the system domain or a configured domain, which takes one facet of a service name; a facet's operations are not resolved, so a facet that names any is refused; its parameters are resolved against its service's declarations | M5 (operations) |
| 3 PCIe configuration space | kept: on QEMU `virt` and on the Raspberry Pi 4 exactly one configured domain, `pcie`, holds the bridge's unit and nothing else; a `pci` device is placed by place on one configured domain, unconfined; a `pci` row names a line only behind the Pi 4's closed bridge, where the VL805's unit is the function at bus 1, device 0 with the INTx line its place routes in the platform's tree, and no other domain holds that line ([design-pcie.md](design-pcie.md#on-fiasco), [design-usb.md](design-usb.md#the-phase-1-part)) | |
| 4 budgets and grants sum | kept for `root_memory`, baseline, shares, the configured domains' budgets and grants and `max_domains`; the configured domains' sums are the planner's (property 12); `root_startup` by the rule below. The sums are checked at build time; nothing enforces them at run time ([Budgets and groups as records](#budgets-and-groups-as-records)) | Track K (`root_startup`, enforcement) |
| 5 names | kept | |
| 6 no JIT in the root | kept; a full boot may use the native root image | |
| 7 the sealing secret | `sealing` is `none`, no entry carries `ERX_ENTRY_SEAL`, no TPM | M11 |
| 8 partitions and devices reach holders | kept: the UARTs are the system domain's; the slot writer's windows, both slots' boot and system partitions and the two records, are the system domain's; the data window is a storage domain's, as the manifest places it; the one read-only `system` window is held by the configured domain that holds its block device, since the block driver hands a window only to its own domain ([The booted slot](#the-booted-slot)); the network device is the network domain's, which runs the network stack; the display domain holds the gpu and input devices; only the system domain holds a facet of the driver-control interface, whichever way its service row names the interface; no vault partition | M11 (vault) |
| 9 a release build's confinement | release builds refused. In a development build every virtio-mmio device is unconfined and allowed, whoever holds it, the display domain's gpu and input devices and the network domain's net device among them, as the property's development clause says; the display domain is reported in the trusted base. The packer sets `ERX_PACK_UNCONFINED_DMA` when the manifest gives an unconfined device, as the property says, and nothing reads it | M11 |
| 10 boot order, 11 rescue, 12 child domains, 13 headroom | kept; 12 runs the host build of `erx_dom_plan_configured` in boot order and `erx_dom_plan_connect` over the introductions, recording each plan, as on erXos's kernel, so the configured domains' sums of 4 and 13 are the planner's; 13 is a configuration check and nothing enforces grants at run time | |
| 14 session templates | kept: a template is a record of the session table, keyed by its principal's name, so a principal has one; its principal exists and its profile has `SPACES`; nothing that resolves through the domain table reaches it, and the domain library's boot view refuses templates out of principal order | |
| 17 start rows, 18 a display's pixel areas | kept | |

**The root startup rule** is a sanity check, not a proof: the root entry's
loadable segments plus `system_baseline` fit `root_memory`, and `root_memory`
fits the platform's RAM less `fiasco_reserve`. `fiasco_reserve` is a number in
the platform record beside `ram_bytes`, the harness's RAM size, and equals the rule
below on that RAM, which the tools check and from which every other machine they boot
(a test machine with more RAM, the website's with less) takes its own. `sigma0`'s
resource dump at 512 MiB on a 4-CPU HVF boot of the fork shows 33.8 MiB it does
not offer the root: 32 MiB of kernel memory, the kernel's image, the device
tree's 1 MiB and `sigma0` itself; at 160 MiB the kernel memory is 10 MiB, and
at 224 MiB it is 6% rounded up, as Fiasco rounds it, to 14 MiB (a boot log's
"Reserved 14 MiB as kernel memory"), and at 256 MiB
the same rule gives 16 MiB. The rule leaves the
archive out: `bootstrap` reserves it whole and it is never released, so a
manifest's `root_memory` must leave it room below RAM less the reserve. The root's place
does not bound it: an archive the root lands on moves behind the root at boot
([Boot handoff](#boot-handoff)). The single file must still lie in RAM and, where the
board's loader puts the device tree at a fixed address, as QEMU's `raspi4b` model does
126 MiB past the file's start, end before the tree; the image build refuses a file past
either (`ProductionImage::Machine#check_single_file`), and prints root_memory's room with
each image. A manifest's `root_memory` is what its
budgets promise and a margin no one is promised, never a figure lowered to make room for
the archive: an archive that outgrows root_memory's room asks for a larger machine. If it
is wrong, the pool fails at boot with a
diagnostic. A platform record without these numbers does not pass.

The packer then holds the archive to that room (`RootStartup.check_archive`, once the archive is
written). The root refuses the boot unless the pool's free pages and its own image hold `root_memory`
(`root_memory_fits` in `liberx/backend/fiasco/root.c`), and what `sigma0` gives it is RAM less the reserve,
the archive and what the boot keeps besides. The packer checks the same inequality: archive plus
`root_memory` at most RAM less `fiasco_reserve` less what the boot keeps.

It estimates what the boot keeps as the platform record's `root_withheld`, plus the contiguous pool the
manifest's devices' memory takes ([The pool](#the-pool)), plus the pool's page index. `root_withheld` counts
Fiasco's and `sigma0`'s images, the device tree, the handoff page, and the pool's object table, the root's
range table and its thread table. The packer sizes the contiguous pool from the
`dma_memory` of the manifest check's report by `RootStartup.contiguous_pool_bytes`, the rule `erx_fiasco_contig_order` applies at boot to
the same total, which `liberx/backend/core/boot_manifest.c` reads from the manifest;
`test/host/fiasco_vm_test.rb` holds the two rules to each other and `test/host/boot_manifest_test.rb` the
two totals. The page index
is `erx_backend_vm_layout`'s, sized over RAM less the reserve and the archive plus the pool's device pages,
which covers every page the pool's own sizing counts.

Boots of the development image at 112, 256 and 768 MiB (the Apple M3 Max host, HVF, QEMU 11.1.3), about
2,600 of them at 256 MiB, on 1 and 4 guest CPUs, each kept 4,321,280 bytes besides the index, counted as
RAM less the reserve, the archive, the pool's pages and the root's image. Each took a 2 MiB contiguous pool,
for the development manifest's 1.25 MiB of devices' memory, so each kept 2,224,128 bytes besides the index
and the contiguous pool; `test/host/manifest_check_test.rb` pins those boots. QEMU `virt`'s
`root_withheld`, 2.5 MiB, errs high by 388 KiB, so the packer refuses an
archive that would boot with less than that to spare, and never passes one that fails while the boot keeps
no more than measured and `fiasco_reserve` is at least the kernel memory Fiasco takes. The Raspberry Pi 4's record states the same for its smallest board, 948 MiB: one boot of the development image on QEMU's `raspi4b` (TCG, 4 guest CPUs, an Apple M3 Max host, QEMU 11.1.3) reserved 58 MiB as kernel memory, its `fiasco_reserve`, and kept 3,837,952 bytes besides the index, 2 MiB of them its contiguous pool, so its `root_withheld` is 2 MiB, 348 KiB high. Neither follows
Fiasco's or `liberx`'s growth by itself, so the boots check the estimate: the root's manifest line reports
the pool's free pages and its image, what `root_memory_fits` counted, and the production image suite
(`RootStartup.check_boot`, seeded in `test/host/production_image_test.rb`) fails a boot whose RAM less
`fiasco_reserve`, the archive, those pages and the image is more than `root_withheld`, the contiguous pool and
the page index.
`root_withheld` is in bytes, and a platform record without it is refused when it is loaded.
`erx_root_plan` replaces the rule behind the same check in Track K.

A test task's program is a boot-image entry named by the boot argument
`erx.test=PATH`, not a `partial_boot` record.

## The production image

`Erx::ProductionImage` (`tools/lib/erx/production_image.rb`) builds the image the
system boots from, and `tools/erx pack` and `make check-reproducible` run it. Its archive
comes through `Pack#build`, the one funnel that takes `Manifest::Admitted`, so nothing
reaches it unchecked. Test images keep `BootImage` and the structural recipe
under `test/fixtures`, whose empty manifest passes the same `Manifest.admit`; the production path loads
nothing from `test/fixtures`, and `production_image_test.rb` checks the loaded files.

No production image carries test code, by construction rather than by a caller's
convention. `ProductionImage#build` takes no additions: its image holds the system
release, the domain release with the boot scripts its manifest names, the runtime images, and nothing else. The one way to add files to that release is the test entry
point, `ProductionImage#build_test_image(directory:, added:, machine:, domains:, manifest_source:)`, which packs them with
`ERX_PACK_TEST_CODE` set in the archive's flags. The packer sets the bit only in a
development build, the archive check and the kernel refuse it in any other, the
kernel's banner prints `test image: carries test code` after the development warning,
and the image's `Built` record reports the bit read back from the archive header. The
production boot check refuses an image with the bit, unless a test harness
asks for a test image's boot, and requires the kernel's
`erx: boot image build` line to report the archive's own identity and flags. The
source check (`Checks::TEST_IMAGE_BUILDERS`, the `test-image-builder` chokepoint rule)
fails the build when Ruby under `tools/` other than `ProductionImage` itself and
the QEMU harnesses that boot test code, which that constant lists, names the test
entry point or hands the packer a literal true for its `test_code` keyword; each harness's boot transcript
checks the banner's test-image line;
`test/host/checks_test.rb` seeds its violations.

Test code may also be a test-only Erlang application, in `test/erlang/apps/` and
listed in `ErlangApps::TEST_ONLY`: the runtime build compiles it beside erXos's own,
no release lists it, and only a test domain boot script
(`ReleaseFiles.domain_boot(..., test: true)`), which the release scripts table never makes,
boots it. A test image's `domains` may carry such a script, which replaces the
manifest's script of its name, and the image build refuses one in an image
without `ERX_PACK_TEST_CODE` (`ProductionImage.check_test_scripts`, seeded in
`test/host/production_image_test.rb`). The system domain suite's configured
server boots `erx_echo_test` this way, to provide a service before its ready report.

A test image may also name a larger machine (`ProductionImage::Machine`): its RAM, from which its
`fiasco_reserve` follows by Fiasco's rule (`Platform.fiasco_reserve`), a growth of the development
manifest's `root_memory`, `system_baseline` and `/tmp` cap, and the root's link address
(`liberx/backend/fiasco/root.ld`), placed as [Boot](design-platforms.md#boot) gives it. No other
line of the manifest changes, and the manifest check proves the grown manifest against the platform
record with that RAM and reserve as it proves the development one. The production image boots on
the development machine, the platform record's own RAM and `fiasco_reserve`; the site image is
packed and checked on the site machine (`Machine.site`), the RAM the website's browser emulator
gives its guest; and `OracleQemu` boots a larger machine, since OTP's suites need more heap and
`/tmp` than the development baseline holds.

| Archive entry | Kind | What it is |
| --- | --- | --- |
| `boot_kernel_path`, `boot_sigma0_path` | file | Fiasco's kernel and `sigma0`, as `bootstrap` loads them |
| `boot_stand_in_root_path` | file | the root as an ELF file, which `bootstrap` loads |
| `system/root` | image | the same program as an image, the header's root entry, which the root startup rule sizes |
| `system_manifest_path`, `system/NOTICES` | file | what `Pack#build` generates |
| `domains/erxos/...` | file | the domain release, which every domain boots from. It holds each file of the applications any of its boot scripts names, once, under `lib/` as in the system release; a boot script `bin/<name>.boot` for each name the manifest's domain rows and session templates give their release, and in a test image for each script its harness adds; the build facts at `releases/build-facts` ([design-shell.md](design-shell.md#text-commands)); and, in a development image whose build was given the development login key, root's login key at `ssh_authorized_keys_path` ([design-ssh.md](design-ssh.md#login-keys)), each the same file as the system release's. The build's release scripts table (`ReleaseFiles::RELEASE_SCRIPTS`) defines each script's applications: the base every domain boots through (`ReleaseFiles::DOMAIN_BASE`) and one kind of domain's own stack. An application in neither the system release's list nor a script fails the build (`ReleaseFiles.check_released`), since it would be booted nowhere, and a name the table does not hold fails the build, so a misspelt release boots nothing. Each script's release file lists only its own applications, so a domain boots only those; it can still read and load any application of the release, which grants nothing, since authority is its capabilities. The session script only loads `erx_session`, which the session template's arguments start with `-eval` once init holds the domain's facets, since its tty relay needs `erx:cap(console)`. A script only loads those of `asn1`, `crypto`, `public_key`, `ssh`, `ssl` and `inets` that it names, so a domain runs none of their supervisors until a program of its own starts them. The index is sorted, so the release is one run of whole entries, which the domain library slices; none carries the system mark, and no other file lies under `domains/`. `<name>` is a manifest identifier, and a domain row's `release @artifact.<name>` names both the run and the script, which `init:script_id()` names. The packer binds the script: it puts `-- -boot /bin/<name> --` between the row's emulator flags and its init arguments, so the binding is init's first flag and no later argument hides it, and it refuses a row whose own arguments name `-boot`; the domain service does the same for a create request's `boot` ([design-domains.md](design-domains.md#erlang-interface)) |
| `runtimes/emu` | image | the domain runtime image: the interpreter ERTS linked as a task's program at `task.ld`'s fixed addresses, since `erx_image_map` loads only an `ERX_IMAGE_FIXED` image; one image for every domain, named as `erx_domain`'s spec names its flavour, with BeamAsm's beside it as `runtimes/jit`, the one entry whose manifest carries `ERX_IMAGE_JIT`, named `@artifact.jit`. It carries no system mark, since the root does not run it, and a domain row's `runtime @artifact.emu` names it |

The root is stored twice because `bootstrap` reads an ELF file while the archive's
root entry is an image by the validator's rule. Track K's planner loads the image
and the file goes.

**Source records.** The kernel and `sigma0` carry an `assembled` receipt over Fiasco's
own receipt, so their notices come from Fiasco's audit. The root carries a `linked`
receipt over its objects, dependency files and the input list its link prints under LLD's `--trace`. Its dependency files leave out
system headers (Fiasco's and the compiler's). Fiasco's three archives that its link takes
members of are registered whole, with the license of the package they come from, since
their members have no compile record a `linked` receipt could name.

**The root's program.** The root is ERTS's interpreter. `Erx::NativeRuntime` builds it with OTP's own
configure and make from `otp/xcomp/erl-xcomp-aarch64-unknown-erxos.conf` in a private copy, over a
sysroot of musl's headers and the root's libraries, and fails if an object imports a name
`sys/erxos/imports.txt` does not list. OTP's own link of `beam.emu` shows that no name is missing.
`NativeRoot` links the root again from `erl_main.o`, `libbeam.a`, OTP's other archives, `libc.a` and
Fiasco's libraries, without debug information, because its link's input list is what the root's receipt reads.
OTP's and musl's archives are registered whole in the source record, with the license of the package
they come from, as Fiasco's are.

**The boot.** The root reports the build identifier, index hash and entry count; then, as numbers
only, `root_memory`, `system_baseline`, the unit count and the pool's free pages; then
`erx: root task: watchdog P,D,B` with the numbers it runs on, or `off` under `erx.det=1`; then it
binds the archive as the release, `erx_release_bind` over the handoff's archive, whose
files under `system/` are what `prim_file` serves, and `erx_release_manifest` and
`erx_boot_manifest_read` give the page the manifest's `system_args`; and it enters musl's start
path. ERTS's first line says `erx: erts: erl_start runs, N arguments`, under the native build's
`ERX_TRACE_START`: the program's name, the node flag with its name, the manifest's words and each
`erx.arg` word. On a machine smaller than `root_memory` the same image ends at the refusal of step 5,
and a command line with a refused `erx.` word at the refusal of step 4. The boot suite's root, built from `NativeRoot::NO_PROGRAM`, says it holds no
program and ends the machine with `ERX_END_OFF`.

The same flag makes `erts_start_schedulers` wait for every normal and dirty CPU scheduler to hold its slot and say `erx: erts: N schedulers and M dirty CPU schedulers hold executor slots`, before any scheduler runs Erlang code, so the line's place in the transcript is fixed.

**Device paths.** Each suite run dumps QEMU's own device tree (`-machine virt,dumpdtb`) and
checks each device path and `compatible` of [config/platforms/qemu-virt.json](../config/platforms/qemu-virt.json)
against it. `/pl011@9040000` exists only when QEMU is given a second `-serial`, which the
harness gives every guest but one, with `erx.hostlink=1` on its command line
([The command line](#the-command-line)): QEMU's null device, or the host link's UNIX socket
([design-live.md](design-live.md#the-host-link)). The one is the production image suite's TCG smoke
boot, of a machine with one UART as the website's is: one `-serial`, no word, and the boot reaches
the command shell with no host link. Under TCG a host link record for the absent UART faults the
root task at the driver's first read, as on the website; under HVF that read does not fault.

## Budgets and the ownership of pages

All of this runs on the service, so a page's state changes one call at a time.

### The pool

At boot the root takes all RAM from `sigma0` with `l4sigma0_map_anypage(pager, window_cursor, order,
&phys, order)`: first one run, the **contiguous pool**, from which every device's memory is made, recording `phys`;
then everything else, at 2 MiB until refused and then 4 KiB until refused. The contiguous pool is one flexpage
of the smallest power of two that holds the total `dma_memory` of the manifest's devices, at least 2 MiB
(order 21, `fiasco_contig_order_min` in `abi/erx_abi.txt`) and at most 16 MiB (order 24, `fiasco_contig_order_max`, which `ERX_MEM_CONTIGUOUS_MAX` fills alone), at a constant of the
address layout aligned to the largest order (`erx_fiasco_contig_order`). Each device's memory is made once and
never given back, and every run is aligned only to a page, so runs of the declared total always fit. A native
test root, which has no manifest, names its own total. The packer refuses a manifest whose devices declare
more than 16 MiB together, or one device more than `ERX_MEM_CONTIGUOUS_MAX`, and counts the same pool in what
the boot keeps ([The Phase 1 manifest check](#the-phase-1-manifest-check), "The root startup rule").
`sigma0` maps RAM read, write and execute (`memmap.cc:96,125`). Cached memory serves for every device: for one
that is not coherent, as the Raspberry Pi 4's are not, the device NIF's cache maintenance keeps the CPU and the
device in agreement ([design-device-dma.md](design-device-dma.md)). The root makes each device's object from its
catalogue entry, records the entry's `dma_bus - dma_cpu`, read from the device tree the firmware handed over, in
it, and gives the device no DMA memory, with a line naming the device, its range and the pool's physical address,
when the entry has no range or the object would lie outside it
([design-device-tree.md](design-device-tree.md#facts-into-records)). Having no resource objects, the backend
takes the entry's range as a value (`erx_mem_create_contiguous_in` of `liberx/backend/api.h`) where erXos's
kernel takes the device's resource, and places the run only where all its pages lie inside the range. One
pure function builds that range from the entry's facts (`erx_boot_dma_range`,
`liberx/backend/core/boot_manifest.c`), and only its two callers make a device's memory: the root's device
step (`device_memory`, `liberx/backend/fiasco/runtime_entry.c`) and the domain library's give
(`apply_give_step`, `liberx/system/dom_apply.c`). No other code calls either create, the identity
`erx_mem_create_contiguous` included, which would give a device with a bus offset its CPU addresses and
spend pool the declared total does not hold; the chokepoint `contiguous-create-callers` fails the build on
a new caller. The pool
is the lowest free RAM `sigma0` has (`Mem_man::alloc_first`, `sigma0/server/src/mem_man.cc`), taken before
anything else of the root's, so it lies inside the DMA window of every supported board's devices, the Raspberry
Pi 4's EMMC2, which sees only the first GiB of CPU addresses, from bus address 0xc0000000, among them.

The window starts at a constant of the backend's address layout, above all RAM, and is never unmapped. The
window's first pages hold [the range table's page index](#the-range-table), sized from how many pages the window holds,
and every page after them goes to the pool.
**A page's identity is its window address.** Only a contiguous pool records a physical address. Free
pages are a list threaded through the pages, and a page is zeroed when taken. An exhausted pool is
`ERX_ENOMEM`.

**Device pages lie below the window.** A contiguous pool and the device window sit at constants of the address layout below the window,
and neither joins the free list. A physical, contiguous or slice object is a table over a run: its pages lie in order outside the pool (a
device's registers, a run of the contiguous pool, or the archive's pages, wherever the root holds them), and each offset's page is the run's start plus the offset. Such a
table holds no page index entry and no label and never takes or gives a page, so no run takes room in the index and no way of ending an
object can free a page a device may still write.

**The device window** is the root's address space from the device base up to the root's UTCB area, which lies below the contiguous
pool, 4 GiB less the root's own pages; one header (`liberx/backend/fiasco/vm.h`) places the UTCB area and `vm.c` asserts the order. Its first pages are the
root's own, which it maps once for its life (the board's random generator and watchdog pages), some before the pool exists. The rest is
handed out as fresh ranges, one for each physical object, the lowest gap that holds it first (`erx_fiasco_device_window_t` in
`liberx/backend/fiasco/page_pool.c`); `sigma0` maps I/O memory to whoever asks, as often as asked (`memmap.cc`: "there is no first-come,
first-serve for IO memory"), so two objects over one device's registers each map them at a range of their own. When the object ends,
after its revoke, the root unmaps its range from its own space and so from every space a mapping was made into from it, and only then
gives the range back: a range taken again holds nothing of the object before, and an object's revoke and unmap reach only the mappings
made from its own range, never another object's over the same registers. A physical object no free range holds is refused with
`ERX_ENOMEM` at its create. It holds QEMU `virt`'s 256 MiB configuration window with room to spare for the registers and BARs the PCIe
domain maps beside it; a board whose windows did not fit would see its domain's creates refused, never a mapping misplaced.

### The range table

A pure core that builds for the host and returns plans (`liberx/backend/core/vm_table.c`). It holds three
facts: runs and mappings per task, and one index for the machine. The **runs** are the task's reserved addresses, sorted and disjoint, in pool pages the task's record takes as they fill ([Table sizes](#table-sizes)); adjacent runs merge, so a range is
wholly reserved exactly when one run covers it. The **mappings** are the task's mapping records, sorted and disjoint, each an address range inside one run, the object, the offset and the rights it was mapped with; a mapped page is never in the page index. The **page index** is a hash from a committed page's address and its table's label (a task's or an object's) to its
window address and protection. A page absent from it is uncommitted, and has no protection to remember, since giving it access
commits it. The index has two slots for each page the window holds. Only a committed pool page takes an entry, and each owns a
distinct window page, so commits never fill more than half the slots and need no pages for it; a table over a run takes none
([Device pages lie below the window](#the-pool)), however many such objects live. The index so never holds more than half its
slots, every probe ends at an empty slot, and a probe visits each slot at most once.

A call computes a whole plan (its range, the state each reserved page in it becomes, and the pages needed), refuses it if the pool
cannot cover it, and only then applies it, so a refused call changes nothing. Each page's steps come from one table of state against
target ([Protection](#protection)): take and zero a page, unmap, map, give the page back.

**Only a fresh map can fail, and it runs first.** A range call meets the rule of
[Who holds what](#who-holds-what) for a step that takes kernel memory: a fresh map, at an address where the task's page table
holds no entry, may need a page-table page and takes a mapping-database node, both from the task's own factory, and either
refusal is `ERX_ENOMEM`. A fresh map is a commit of an uncommitted page, or a raise of rights on a committed page with no access,
whose entry the drop to no access cleared (`Mem_space::v_delete`, `arm/mem_space-arm.cpp:334-337`). Every other step needs no
kernel memory: an unmap frees; a raise of rights over a present entry finds the entry at its level, so the walk allocates nothing,
and it is an attribute upgrade, which adds no mapping-database node (`map_util.cpp:748`); and a drop of a right other than read
keeps the entry (`arm/mem_space-arm.cpp:322-340`). So applying runs every fresh map of the plan first, in ascending address order,
and only then the steps that cannot fail, also in ascending order. A fresh map Fiasco refuses unmaps the fresh maps before it,
returns to the pool the pages the plan took, and answers `ERX_ENOMEM`; a committed page with no access whose fresh map is undone
stays committed with no access, its contents kept. The call changes nothing, as a refused plan does, and the failure is the
domain's own. Commit and decommit pass over holes, as the kernel's do; a protect that meets a hole is `ERX_ERANGE`. A commit,
decommit whose range meets a mapping, and a release or a fixed reserve that covers part of one, is refused whole with `ERX_EINVAL`, and a protect that meets one with `ERX_ENOTSUP`.

* **Commit:** an uncommitted page takes a page, zeroes it, and `l4_task_map(task, L4_BASE_TASK_CAP, l4_fpage(window,
  L4_PAGESHIFT, prot), l4_map_control(addr, 0, 0))`. A committed page is present, and one already committed becomes read-write as [Protection](#protection) says.
* **Decommit:** `l4_task_unmap(task, l4_fpage(addr, L4_PAGESHIFT, L4_FPAGE_RWX), L4_FP_ALL_SPACES)`, unless the page has
  no access and so no mapping, and the page returns to the pool.
* **Release:** decommit what is committed, unmap and drop each mapping the range covers whole, drop the addresses from the runs. `ERX_VM_FIXED` over reserved addresses does this first.
* **Revoke** (an object going while mapped): `l4_task_unmap(L4_BASE_TASK_CAP, l4_fpage(window, L4_PAGESHIFT,
  L4_FPAGE_RWX), L4_FP_OTHER_SPACES)` for each of its pages, which removes every derived mapping in every task and keeps the window's;
  its mapping records are dropped from their tasks, then the pages return to the pool.

### Protection

`erx_space_protect` works on the page's record, so it cannot lose contents. Dropping a right is
`l4_task_unmap` with that right. Raising is `l4_task_map` of the same window page at the same address,
which **adds rights and never replaces them** (`map_util.cpp:643`, `mem_space-arm.cpp:241`) and invalidates
no entry when the memory type stays (`page-arm.cpp`, `is_attribs_upgrade_safe`). So a change in both
directions drops first. Write means read and write, execute means read and execute.

| From | To | Steps, in this order |
| --- | --- | --- |
| uncommitted | no access | nothing: the page stays uncommitted |
| uncommitted | R, RW or RX | take a page, zero it, map it with the target: K4's commit on access change, and musl's guarded stack (`pthread_create.c:295-297`) |
| no access, or R | R, RW or RX | map the same window page with the target; nothing from R to R |
| RW or RX | R | unmap the write or the execute right |
| RW | RX | unmap write, then map RX |
| RX | RW | unmap execute, then map RW |
| any | no access | unmap all rights; the page stays committed, its contents kept |

Pages change in ascending address order. A thread touching a page against the change faults, which is its
own bug, as it raced its own `mprotect`.

**The root as sender and receiver.** The root's own ranges use the same call, with `L4_BASE_TASK_CAP` as both
destination and source (`lock_guard.cpp:255`), which Fiasco accepts.

### Shared objects and the JIT alias

A shared object is a range table of its own over offsets, under a label of its own, so its pages are ordinary entries of the
page index: each owns its window page, the pool hands them out, and they come back by the release every table has. They are all
committed when it is created. `erx_vm_map` maps each page with the requested rights, so a
read-write alias and a read-execute alias are two mappings of one window page. The index holds no entry for a mapping, since an entry owns
its page, so the object's pages keep the index's bound; the mapping record is the mapping's one entry. A map goes only to addresses
that hold neither a committed page nor a mapping, so no map meets an earlier right at its address, and no call leaves a task's page
writable and executable at once. No task's mapping has write and execute at once. The pool window itself does, in the root, so M4
checks the range table and tests each JIT alias by a fault, and the page-table walk belongs to M7.

**An object's record** holds its kind, its creator's task, its budget, its pages or its physical range, its sealed flag, the
count of handles that name it in any table and the count of its mapping records. A revoke needs no list of them: one unmap of
each window page removes every mapping in every space, and the records go by a walk over the tasks' tables, whose cost Phase 1
asks no bound of. An object goes at the first of four events, each a step of one service
body:

| Event | What the body does |
| --- | --- |
| `erx_object_destroy`, by its creator's task | revoke, drop the record, free the pages |
| its budget's destroy | the same, as one step of the budget's walk ([Budgets and groups as records](#budgets-and-groups-as-records)) |
| its creator's task ends | the same, as one step of [task exit](#task-exit) |
| its count of handles and its count of mappings both reach zero, by a close, a release or a task's end | free the pages; nothing is mapped, so nothing is revoked |

The last row is erXos's release by the last reference, which a pipe's memory relies on
([design-pipes.md](design-pipes.md)); the first three can find an object still mapped, and the revoke makes every task's
mapping of it go at once, as a deletion does on erXos's kernel. The third row has no counterpart there, and can find no
holder: [handles flow down](#erxos-on-fiasco), so every task that holds or maps an object a task created is that task
or one below it, and those end first. A physical object's range of the device window goes back once its pages are unmapped from every space, and a contiguous object's run is
never given back ([The pool](#the-pool)); a slice's pages are the archive's, which no event frees. The image slices `erx_image_map` keeps, one per image entry it has mapped, are the root's, charged to its budget and named by no handle, so none of the four events reaches them.

### Reporting a budget

The pool keeps a count of the pages it handed out and has not taken back, and each budget record a count of the
pool pages charged to it ([Memory and budgets](#memory-and-budgets)). The budget
topic asked on the root's budget writes the pool's count as `used` with every bit of `reported` clear, and
`erx_info_partial` names `used`, so the
inspector shows it as **partial**, reporter `root pool`, scope "pages of the root's pool: those handed out, carved
budgets' included, and the pool's total and free; not the kernel's or sigma0's memory, page tables or mapping
records", and a reader of the report alone sees `used` as not reported. An image entry's code and read-only data are the archive's own pages, shared by every space that runs it, so they are in no budget's count and not in the pool's: of a domain's image, `used` counts only its writable segments. Of the root's budget, which has no record, `kind`,
`guarantee`, `cap`, `carved`, `lent`, `pinned` and `threshold` are `unsupported`, reported as `kernel`'s, since
the kernel interface answers that it does not report them. The reporter of `used` is the backend reporter `liberx_pool` of `abi/inspection.txt`, which stands in for `kernel` and
declares that label and scope ([design-abi.md](design-abi.md#inspection-schema)); a record carries it as
`{backend, liberx_pool}` ([design-live.md](design-live.md#inspection-records)). The root's count includes the pages
of every budget carved from the root's, which is why it is partial and not the kernel's `used`. The budget topic
asked on any other budget, a domain's, a connection's or a program's, writes the record's own count as `used`,
**partial** under the same reporter, since the count holds the budget's pool pages and not its kernel memory,
and its `guarantee`, `cap` and `carved`, the sum of its children's
guarantees, as reported, since the record holds each exactly. `kind`, `lent`, `pinned` and `threshold` stay
`unsupported`, and exact `used`, kernel memory included, waits for erXos's kernel (FD25).

The machine topic takes its memory from the same pool: `memory_total` is the pages the pool was built with and
`memory_free` those it holds now, each in bytes, with their `reported` bits clear and `erx_info_partial` naming
both, so the inspector shows them as **partial** under the same reporter. They count the RAM the root's pool took
from sigma0, not the memory Fiasco keeps for itself or sigma0 holds back, which only a kernel can count; a reader
that wants the exact figure gets none, and `top` prints the numbers under the label `Mem (root pool)`. `uptime` is `liberx`'s clock, reported whole: the
time since the counter started, which on a board includes the firmware's time before Fiasco. The hosted backend
reports the host's `CLOCK_UPTIME_RAW`, and its pool's pages, the same way.

### Budgets and groups as records

The domain library builds and ends domains by budgets: it carves a domain's own and outer budgets, charges
everything of the domain to one of them, and undoes a failed creation, ends a domain and retires a connection by
destroying a budget ([design-system.md](design-system.md#creating-a-domain)). A session does the same for each
program. So a budget is a **record** of the root's, whose cap the root holds its user pages to and whose kernel
memory is a Fiasco factory ([Memory and budgets](#memory-and-budgets)), and it keeps the one property those
callers rely on to clean up: **an object goes with its budget.**

* **A budget record** is an object record of kind budget, and holds its parent, its wall, and its `used` and
  `carved` under the one invariant of [Memory and budgets](#memory-and-budgets). `erx_budget_create` makes one, from any
  task, under any budget its caller holds or under its own, as a session carves each program's budget from its own,
  adding its wall to the parent's `carved` and refused where the parent's invariant would break;
  `erx_budget_resize` takes a guarantee and a cap that must be equal, records the one wall and moves the parent's
  `carved` by the difference in the same request, the kernel-memory part fixed at creation (FD25), and is refused
  below the record's own `used + carved`;
  a charge past the cap is refused ([Memory and budgets](#memory-and-budgets)). Only the domain library resizes, in the
  root, so a task's resize is `ERX_ENOTSUP`. A budget record is in its creator's handle table. A task holds a
  budget's handle when it made the budget or the domain library's install passes it one, and may hold its last; a
  budget it holds that way ends after the task's end, not inside it, as every object its end frees does
  ([task exit](#task-exit)), so no budget's sweep meets a space whose end is under way. The root's own budget, `ERX_CAP_SELF`'s in the root, has no record, since
  only the machine's end ends it and nothing resizes it. Every object record, space and group names the budget it
  was created from; a create that names `ERX_CAP_SELF` charges the budget its caller's own space is charged to.
* **Destroying a budget** is one service body, run at its destroy and at its last handle's close alike, as
  for every object. It sweeps the object table flat, never by a walk that recurses: a record is below the
  budget when the chain of parents from the budget it is charged to reaches it. The first sweep stops and
  deletes every space below it, and the home task of every group below it that still has a thread
  ([task exit](#task-exit), children first); the second deletes every other object below it, groups, IRQ
  objects, gates and memory alike, as the [object table](#shared-objects-and-the-jit-alias)'s second row
  says; then each further sweep frees the carved budgets nothing is charged to any more, leaves first, until
  a sweep frees none, and the budget's own record goes last. A deletion the root cannot perform ends the
  machine, as every deletion does.
* **A group record** holds its budget and its home: the task its threads run in and the
  park record of that task ([Interrupts and readiness](#interrupts-and-readiness)).
  The record is an object record in the creator's handle table, and its home is the home task's row, so a task is
  the home of one group at most. `erx_group_create` makes one, from any task, under any budget its caller holds or under its own, with no
  home; the root's first also starts the root's dispatcher in it, which makes it the root's own group. The first
  `erx_thread_create` in the group fixes the home to the thread's task, and a thread of another task is
  `ERX_ENOTSUP` after that, the refusal of a call this backend does not carry, since erXos's kernel runs a
  group's threads in any space. In every caller the first thread created in a group belongs to the task the group was
  made for: the domain library's first worker of a domain, a session's first thread of a program, the root's
  dispatcher. A thread that names `ERX_CAP_NULL` joins no record and parks in its task's park record, as the
  root's executors and every task's own threads do. A group goes with its budget, with
  its home task, or by `erx_object_destroy` once it has no thread; while its home has a thread, the close of its last handle leaves it to go with that home. **A group never goes before its threads:**
  a thread is deleted either by its own exit through the reaper, which also releases its stack and clears its
  lock word ([Thread exit](#thread-exit)), or with its whole task, so the service never deletes threads of a
  live task one by one. Hence the destroy of a group that still has a thread is `ERX_ENOTSUP`, and a budget's
  destroy stops such a group's home task. Each caller ends a group's home first anyway: the domain library and
  a session destroy a domain's or a program's budget, which stops its spaces. Where erXos's kernel ends a
  group's threads at its destroy, this backend refuses; no consumer needs it.
* **Deleting a group** detaches every IRQ object bound to it with `l4_irq_detach` and drops its bind records,
  pending ones included ([Interrupts and readiness](#interrupts-and-readiness)), so a holder's later trigger
  waits at the object, as for any unbound object. The home is the backend's
  own: no call reports it, and threads are listed by space, as on erXos's kernel
  ([Reporting kernel objects](#reporting-kernel-objects)).

A budget's guarantee is its wall ([Memory and budgets](#memory-and-budgets)). A group's grant binds nothing at run time
(FD15), and the inspector shows a budget record's `used` as partial and its `guarantee`, `cap` and `carved` exact, and
of the root's budget only `used`, partial ([Reporting a budget](#reporting-a-budget), FD25).

### Table sizes

The service's tables are pool memory, so the only limits are the pool's, a domain's row's and the ones erXos's interface
itself has, and the root's slot pool, which Fiasco's object space bounds.
Each table is a directory page of window addresses of its pages, and a table that fills takes one more page from the
pool: the task table, the object, budget, group and gate records, each task's handle table, runs and mapping records.
A table never moves, since its pages stay where they were taken, and every reference between records is an index,
since the service keeps no pointer across a receive. A table that cannot grow is `ERX_ENOMEM`.

| Table | Limit |
| --- | --- |
| a task's handles | the `cap_limit` its creator gave `erx_space_create`, which the domain library takes from the domain's runtime limits; past it `ERX_ELIMIT`, as on erXos's kernel; the root's, 16,384, its window in the root's layout ([Handles](#handles)) |
| a task's threads | 128, the most one Fiasco UTCB area holds ([Thread creation](#thread-creation)) |
| a task's home groups | 1, a park record made with the task |
| a group's bound IRQ objects | 64, the ready list's length |
| a domain's threads, objects and mappings | its row's limits, its sub-spaces' included; past them `ERX_ELIMIT` ([Memory and budgets](#memory-and-budgets)) |
| tasks and memory objects together | 4,096, the page index's labels, shared out among domains by their object limits at admission, the configured domains' shares reserved so that no session takes what a configured domain's restart needs, which the manifest check proves ([design-packaging.md](design-packaging.md#the-builds-check), property 19's clause 9) |
| tasks | 1,024, the task table's two rows a page in its one directory page, derived from the row's size; a space is an object, so the table is shared out among domains by their object limits at admission, the configured domains' shares reserved, which the manifest check proves ([design-packaging.md](design-packaging.md#the-builds-check), property 19's clause 9) |
| the root's slot pool | 24,312 pairs, what Fiasco's object space leaves past the root's fixed slots ([Handles](#handles)): two pairs for each task row, held back whole, and the remaining 22,264 for threads, one pair each, shared out among domains by their thread limits at admission, the configured domains' shares reserved, which the manifest check proves (clause 9); past it `ERX_ENOMEM` |
| any one table | 512 pages, its one directory page; a task's runs 131,072 |
| everything else | the pool |

The page index stays sized at boot from the window ([The range table](#the-range-table)), which bounds it by
construction.

### Kernel memory and the root budget

Fiasco's objects, page tables and mapping records come from its own allocator, sized at boot: a domain's from its
factory, and what the root holds for every domain from the root's own quota, which domain admission shares out
([Memory and budgets](#memory-and-budgets)). A call that fails for lack of it is `ERX_ENOMEM` and undoes what it created ([Who holds what](#who-holds-what)), so a domain that spends its factory fails alone; exhaustion on a path that cannot fail is inherited.

## Threads, waits and exit

### Scheduling

Fiasco's fixed-priority scheduler schedules every thread; ERTS schedules its processes within them. Every thread
starts at the base of its task's band and never runs above the band's ceiling ([Bands](#bands)), within its domain's
CPU set and with its domain's slice as its quantum, all from the domain's row in the root, which the domain's limits
record and its grant fill.
`l4_scheduler_run_thread(L4_BASE_SCHEDULER_CAP, thread, &param)` starts each thread, with `param` holding the
priority and the quantum and, in `param.affinity`, the thread's mask within its
domain's CPU set ([Threads, bands and stops](#threads-bands-and-stops)): the requested mask, or every CPU when none
was requested, intersected with the domain's set and the online CPUs, which admission makes non-empty. Within that
mask Fiasco puts the thread on one CPU: its home CPU if the mask holds it, else the CPU of the thread that starts it,
which for a task's threads is the root service's, if the mask holds that, else the mask's first CPU
(`scheduler.cpp:96-103`). Fiasco's kernel sources hold no load balancer (a search of `src/kern` for one finds none), so a thread stays where it
was placed, and so a domain's threads started with no
mask share one CPU of its set rather than spread across it, until an affinity request moves them
([the performance watch list](todo-performance.md)). `erx_thread_set_affinity` before the start takes effect at the start,
and after it moves the thread at once, through the same call; a mask whose intersection is empty is
`ERX_EINVAL` and changes nothing. An affinity change keeps the thread's level, which the root passes
again from the thread's row ([Urgency](#urgency)), and refills its quantum
(`Thread::set_sched_params`, `thread.cpp:704`), so a thread that asks for one every slice keeps its
CPU from the others of its level; only an app is hostile, and it shares only the app level (FD15).

**The quantum.** A thread's quantum is the `slice_us` of its domain's grant, 1 ms in the development manifests, in
place of Fiasco's default of 10 ms (`CONFIG_SCHED_DEF_TIME_SLICE`, `src/Kconfig:361-367`). The quantum is what a
ready thread waits for each thread ahead of it at its level ([Bands](#bands)), and for each thread that a wake puts
ahead of it meanwhile, so it sets the step, not the bound, of what the base level's round robin costs a runtime whose
executor is awake but not running ([Urgency](#urgency)). A slice ends at a timer interrupt, which with a periodic tick comes every
1 ms (`CONFIG_SCHED_GRANULARITY`, `src/Kconfig:353-359`). erXos's build ticks: `config/fiasco/kernel.defconfig`
chooses no timer mode, so Kconfig takes its choice's first, periodic (`src/Kconfig:258-265`), and a slice ends at the
first tick after it runs out. The quantum case measures the turn a thread gets ([Verification](#verification)).

**Where ERTS puts its schedulers.** Since Fiasco never moves a thread, the adapter places them, as it does under
erXos's kernel ([design-runtime.md](design-runtime.md#scheduling)): online normal scheduler `i` is pinned with
`erx_thread_set_affinity` to the `i`-th CPU of the group's run, and on Fiasco dirty CPU scheduler `i` likewise, since
no kernel places it at its wake. The run is the one the group's configured capacity names within the domain's CPU
set, and a runtime starts as many normal schedulers as the run has CPUs. So on each CPU a runtime has one normal
scheduler, and no normal scheduler waits behind another; a dirty CPU scheduler shares its CPU with that CPU's normal
scheduler and takes turns with it at the base level, where dirty work stays. The runtime's
urgent scheduler, where it has one, is pinned to the run's first CPU, above them all ([Urgency](#urgency)). Left unpinned, all of a domain's schedulers share the root service's CPU and take turns there, which is the
delay the Raspberry Pi 4's probe measured ([Bands](#bands)).

**A wait blocks.** A thread that waits for something another thread does blocks in Fiasco, in `erx_park`, a umtx
wait, a semaphore or an IPC, and never waits by spinning or by yielding. Two of Fiasco's properties make that a
rule and not a preference:

* a wake preempts and a ready thread queues ([Bands](#bands)), so a thread that blocked hears of its work at once,
  while one that spins or yields is awake, is woken by no one, and learns of the work when its turn comes round;
* a yield reaches only ready threads of the yielder's own priority on its CPU, and a spin reaches no one, so a
  waiter above the thread it waits for, on that thread's CPU, keeps it off the CPU and waits for ever.

So ERTS's busy waiting is off in every runtime on Fiasco: `+sbwt none`, `+sbwtdcpu none` and `+sbwtdio none` are the
adapter's defaults, as under erXos's kernel, and `very_short` is not selectable on Fiasco. A spinning scheduler
counts as awake, so a trigger wakes no one for it ([The park protocol](#the-park-protocol)) and the delivery waits
for the spinner's turn: on the Raspberry Pi 4, with spinning off none of 54 receipts of the SD controller's line took
over 1 ms, and with `very_short` 7 of 53 did (history repository, `pi4/2026-11-22-irq-probe/`, images E and F). A
test's root waits for its tasks the same way, by a sleep or a wait, never by `erx_yield` in a loop, which keeps
every lower level off its CPU.

The price is a park for every idle moment, two kernel entries and a switch through the task's dispatcher (FD16).
Under HVF on one CPU the boot to the release shell takes a median of 818.8 ms with spinning off against 642.8 ms
with stock ERTS's spinning, 694.5 ms with `very_short` and 654.8 ms with `short` (history repository,
`bench/2026-11-22-spin/`: an Apple M3 Max under load, QEMU 11.1.3, clang 23.1.3, 11 boots each), the likely reason, unverified, being that
there a spinner's yield hands the one CPU to the thread that produces its work and saves both parks. That saving exists
only while the thread yielded to finishes at once; the same yield to a thread with a slice of work is the 1 ms
receipt above. What brings the saving back without the delay is a cheaper park, stage 4
([Stages beyond bands](#stages-beyond-bands)), and the cost on the Raspberry Pi 4 itself is not measured
([the performance watch list](todo-performance.md)).

**A yield.** `erx_yield` and musl's `sched_yield` through it call `l4_thread_yield`, which is a receive from the
thread itself with a zero timeout. Upstream
Fiasco's receive phase marks that timeout as hit before it would wait, so the call returns at once and the caller
keeps its CPU to the end of its time slice. The fork changes one thing in `Thread::do_ipc_receive` (`thread-ipc.cpp`): a receive from the thread itself whose
timeout hit before it would wait calls `Thread::yield_timeslice`, which puts the thread's own scheduling context behind
the other ready ones of its priority, as a receive from itself with a timeout to wait does, and schedules. The thread
stays ready and gets the timeout result when it runs again. So a yield hands the CPU to the next ready thread of its
priority on its CPU, a thread alone at its priority there runs on at once, and no yield reaches a thread of a lower
priority. A yield is for giving equals a turn; it is not a wait. The native task suite's `yield` case is its test.

**A call's slice.** Every message to the root service leaves the tag's `Schedule` flag clear: a stub's
`l4_ipc_call`, whose tag carries no flag (`service_stubs.c:48-49`), and the page-fault and exception messages Fiasco
sends for a thread (`thread-ipc.cpp:299`, `:977-978`). So Fiasco lends the caller's time to the service
(`L4_msg_tag::do_switch`, `abi/l4_types.cpp:946-947`): when the service waits on the caller's CPU and no other message
is queued, a call switches straight to it without choosing its scheduling context (`thread-ipc.cpp:536-549`,
`:788-805`), and the service's body runs on the caller's scheduling context, at the caller's level and on what is left
of the caller's quantum. The loan ends at the first reschedule on that CPU, at the slice's end or when a thread that
outranks the caller wakes: the service then joins the ready queue on its own scheduling context, at the base level
(`Context::update_ready_list`, `context.cpp:1032-1038`). A call from another CPU lends nothing, and the service wakes
on its own context. erXos keeps the loan, because each of its cases is work the bands allow:

* an urgent caller's body runs at the urgent level on at most that caller's remaining slice, work that ends, asked by
  a thread of the root or driver band, so a driver's allocation does not wait behind the base level;
* a base caller's body runs at the base level, as it would on the service's own context, without a pass through the
  scheduler;
* an app caller's body runs at the app level only while nothing above it is ready on that CPU, and the first thread
  above it that wakes moves the service to its own context at the base level, so the root service is never left at
  the app level behind the base level's work.

So the root service never sets its own urgency, and above the base level it runs only its caller's request, on its caller's
time. That the loan ends at the first reschedule is read from `Context::schedule` (`context.cpp:897-972`) and is
unverified until the donated-call case runs ([Verification](#verification)).

**Locks and priorities.** A task's threads run at two priorities, its band's base and ceiling, and the root service
shares the root's locks with the system domain's threads at either, so a backend lock is one whose waiter blocks
([Locks](#locks)). A waiter that preempted the holder on their CPU thereby gives the CPU up, and the holder, the
thread it preempted, runs on to its unlock, which wakes the waiter; a waiter on another CPU blocks until the unlock
the same way. The holder is not raised to the waiter's priority, so a waiter at the ceiling waits for whatever runs
ahead of a holder at the base: other urgent work, which it would wait for anyway, a slice of each base-level thread
ahead of the holder on its CPU, and every base-level thread that wakes there before the holder's turn, since a wake
goes in front ([Urgency](#urgency)); that wait has no bound but that CPU's base-level load. Fiasco's priority-inheritance mutex
(`pi_mutex.cpp`) would end that wait, and is not used: its fast path names the owner by a thread capability, which
no task holds (`pi_mutex.cpp:695-696`; [Who holds what](#who-holds-what)). The watchdog, at 255, takes no lock.

### Thread creation

**The thread table.** Made with the task: 128 **records** of 2 KiB, in 64 committed pages at a constant address,
whose window addresses the service keeps. A record starts with the thread's public UTCB
([Transport](#transport)), followed by the starting registers, a free or used state, the semaphore's slot, the
group slot, the word to clear, the range to release and the umtx node.

The same indices own 128 native UTCB slots of 1 KiB, the most one Fiasco area holds (`task.cpp:356`), zeroed by
Fiasco (`task.cpp:253`). `l4_factory_create_task`'s `utcb_area` makes them for a task, and one
`l4_task_add_ku_mem` for the root, whose first thread keeps its kernel-given slot as index 0. The root's service
thread holds no index: it runs before the table's area exists and is no client of it, so it takes the next free
slot of the kernel-given UTCB page.

**Claiming an index.** Fiasco writes `free_marker` when finished with a UTCB, in `do_kill`, some time after the
deletion call returns (`thread.cpp:603-604`, `utcb.h:176-185`). So an index is claimable when **its record is
free and its marker reads 0**, checked under the thread lock, lowest first, as L4Re checks (`manager.cc:541`).
Only `erx_thread_start` and the trampoline set a marker, and only Fiasco clears one. No claimable index is
`ERX_ENOMEM`.

**A semaphore's wake across CPUs.** The fork changes one thing in `Semaphore`. An up on another CPU dequeues its waiter and activates it afterwards, and the waiter's timeout can fire in between. Its down then reports success, as it must, since the count went to it, but the activation is still on its way, and it would end whatever the thread blocks in next: an IPC wait with a false timeout, or another down with success and no up, leaving the thread queued. So the activation carries `Thread_sem_woken`, and a down that finds its thread dequeued waits for that bit before it returns. No semaphore's activation outlives its down, so no other wait has to expect one.

**`erx_thread_create`.** The stub claims an index. The service runs `l4_factory_create_thread` and
`l4_factory_create(factory, L4_PROTO_SEMAPHORE, cap)` (`factory.h:470`, `semaphore.cpp:329`), maps the semaphore
at the index's slot, copies the starting registers from the caller's public UTCB into the record, and replies
with the handle and the slot, which in the root is the root's own capability. The starting registers are
`erx_fiasco_start_t`: the ABI's `erx_regs` and, beside them, the thread pointer, which `erx_regs` does not hold.
**Thread handles.** A handle to a thread of the caller's own task, in the root and in every other task alike, names the
thread's index, since the stubs of `erx_thread_start` and the exit path work on the record it names locally; it
carries no generation and is no entry of the handle table. The two kinds of handle are told apart by the slot bits,
bits 0-23 of the value ([Handles](#handles)). An entry's number there is its index plus one, so 0 stays `ERX_CAP_NULL` and
every entry number lies at or below `cap_limit`, within `caps_max` (`abi/kernel.txt`). An own-task thread handle is `ERX_FIASCO_THREAD_HANDLE_BASE` (`0x800000`) plus the index:
like `cap_self` and `cap_self_thread`, it lies above `caps_max` in the slot bits, where no entry can be, and below both
of those values, since an index is less than 128. Every call that takes a thread handle checks for the base first. Once the thread is reaped the handle names no thread and is
refused, until the index's next create, from which on it names that thread, a recorded difference; nothing keeps such a
handle past a join, since `pthread_t` is musl's own. On failure the stub frees the record and returns the service's
status.

A task names itself or a space it created as the space. In a space it created, a caller makes only the first thread,
the one the domain library or a session starts a domain or a program with, and a second create there is `ERX_ENOTSUP`;
the space's own threads make the rest. That first thread takes index 0, and its creator's stub claims nothing, since the
service makes the table with the task. Its handle is an ordinary entry of the creator's handle table naming index 0 of
that task, with no generation of the thread's own, so once the thread is reaped the handle names no thread until the
index is reused, and then names the new thread (FD2). Any task makes the
first thread of a space it created, as a session does a program's. A handle naming another task's thread names one
only when the caller is the root or created that task, as its space record's creator shows, so a task starts no thread
of a space it did not create. Its start is a request, and the task's own entry marks record 0
started when the thread first runs, as the root's does, and the trampoline below writes its marker.

**`erx_thread_start`.** The stub moves the record from created to started, and only then writes the marker 1: a start of any other handle
is refused untouched, since a 1 written over the kernel's 0 would lose the index for good. The service, in order:

1. `l4_thread_control_start`, `_pager` and `_exc_handler` naming the task's gate, `_bind(slot, task)`, `_commit`.
2. `l4_thread_ex_regs(thread, trampoline, record, 0)`. The trampoline's address comes in the start request, as each task's image has its own. A task's first thread starts at the `pc` of the starting registers its creator wrote, as on erXos's kernel: the image's entry, which `erx_image_map` returned to the creator, with its arguments beside it: a domain's boot information page in the first argument register, and a program's values in the registers `abi/erx_abi.txt`'s `program_arg` names. The image's first instructions put the task's first stack and its C entry in the record and go to the trampoline.
3. `l4_scheduler_run_thread`.

Starting a thread twice is `ERX_EINVAL`.

**A failed start.** If any step fails, the service deletes the thread and its semaphore with `l4_task_delete_obj`,
drops the handle, and only then replies with the failure. So the thread cannot run on a stack the caller now
frees (`pthread_create.c:384`): it was never runnable, or the deletion's return means it never reaches user mode
again (`thread_object.cpp:157-166`, `thread.cpp:657-690`). The stub frees the record and leaves the marker, which
is safe either way: if Fiasco ran its kill path it writes 0 and the index returns; if it only unbound the thread
the marker stays 1 and the index is lost until the task ends. A deletion the root cannot perform ends the machine.

**The trampoline.** `l4_thread_ex_regs` carries no thread pointer (`thread.h:94`), so `ip` is a few lines of
assembly in the backend's architecture layer and `sp` is the record. It stores the record in the native UTCB's
first user word, as L4Re's pthread does (`descr.h:211`), writes the marker 1, which index 0 needs because the
root cannot reach a task's native UTCB, sets the stack, the thread pointer and the first eight argument registers
from the starting registers, and jumps to the entry. A program's values, `program_arg`, use all eight: `budget` to `hwcap2` in registers 0 to 6 and `exec`,
0 in every start a session gives, the loader's included, and the exec record's page, `exec_record_page`, only
in the start `erx_exec`'s exec entry gives, in register 7, so a further value a session gives its program travels in the
startup message, not in a register. `task_start.c` and `program.c` assert that `exec`, the highest index, is
below `ERX_ARCH_START_ARGS`, which holds only while `exec` stays the last value.

**An exec's entry.** `erx_exec` ([design-programs.md](design-programs.md#what-a-program-can-start), "The loader's
bootstrap") is linked as every task is, but its first instructions name its own C entry, which readies record 0 as
`erx_fiasco_thread_first_init` does, so that its memory calls reach the service, and loads the executable before
`erx_fiasco_task_main` would start the reaper and the dispatcher. It calls that function, as a C function on its own
first stack, only when the load fails, to report the failure as a program: it first copies the load's reason into a
static of its own image, which its `main` writes, and passes the eight arguments as it received them, the eighth
0, so its own `erx_prog_enter` sees no loader behind it and never runs `erx_exec_release`. The loader's
window, its image, the rest the load reserved and the exec record, stays mapped on that path and goes with the task. On success its exec entry, a few instructions beside the trampoline, writes into
record 0 what the session's start wrote there: the eight starting arguments, the `program_arg` values with the
exec record's page, `exec_record_page`, in the eighth, and the thread pointer 0. It then sets the stack pointer to record 0 and
branches to the executable's entry, which is that executable's `_start` (`task_start.S:19-28`): `_start` stores its
own first stack, `task_stack_top`, and its own C entry in the record and goes to the trampoline
(`thread_start.S:25-41`), which loads the stack, the thread pointer and the arguments from the record exactly as at
a first start. The thread's UTCB already names record 0, and the thread records lie at the fixed `THREAD_TABLE`
address outside both images (`thread.c:96-100`), so the executable's `erx_fiasco_thread_first_init` readies the
same record again. A C call of `_start` would leave the stack pointer on `erx_exec`'s stack, which `_start` would
take for the record. The 256 KiB first stack `erx_exec` ran on is its own `task_stack_top`, in its data segment
(`task_start.S:30-34`), and goes with the loader's window when the executable's start-up releases it. That release
is `erx_prog_enter`'s, which the executable's program entry, `erx_task_main` (`program_task.c:341-346`), calls
before `erx_fiasco_libc_start`, so musl's start and the constructors it runs find the loader gone, and the backend
names no part of the release; the reaper and the
dispatcher, which `erx_fiasco_task_main` starts first (`task_start.c:77`), are `liberx`'s and never touch either
image's pages. A window `erx_exec_release` refuses, a release the space refuses, and `erx_exec`'s own refused
cleanup all stop the task with the program layer's one status for them, `ERX_PROG_STATUS_RELEASE`, beside
`ERX_PROG_STATUS_REFUSED` (`liberx/program/startup.h:35`). Neither image is ever entered twice, and the task never holds
two reapers or two dispatchers.

**Musl's thread identifier.** `self->tid` is the index plus one: nonzero for `__tl_lock`'s `a_cas(.., 0, tid)`,
and within the 30 bits `pthread_mutex_trylock.c:8-12` compares. The record is freed after the reaper's last step,
so no live thread shares an identifier with a stale lock word. `SYS_set_tid_address` (`__init_tls.c:22`) and
`__clone` store their address as the record's word to clear.

### The umtx table

One table per task, in its own memory, keyed by address, under the umtx lock: a pure state machine, shared with the
TSan model. Each waiter is a node in its record.

* **Wait:** under the lock, load `*addr`. If it differs from `expected`, return `ERX_OK` (musl treats that as a
  spurious wake). Otherwise enqueue. After the lock, `l4_semaphore_down(own, timeout)`.
* **Timeout:** on `L4_IPC_RETIMEOUT` (`restart.h:81`), take the lock. If the node is queued, remove it and return
  `ERX_ETIMEDOUT`. If a waker dequeued it, its up is on the way: absorb it with an unbounded down and return `ERX_OK`.
* **Wake:** under the lock, dequeue up to `count` waiters in order. After the lock, `l4_semaphore_up` each, and
  return how many.

**An invariant shared with [the park protocol](#the-park-protocol): a thread taken off a list is owed exactly one
up, and only such a thread is.** So a semaphore holds 0 whenever its thread enters a wait, and a thread taken off a
list stays until its up arrives, which keeps its record valid for the waker. A wait compares under the lock and a
waker stores the word before taking it, so no wake is lost. A bad address is a fault, and nothing in Phase 1 shares a
word between tasks.

### Deadlines

A deadline is absolute monotonic nanoseconds. The backend reads the architecture's user-mode counter directly, through
`erx_fiasco_clock_ns` in the architecture layer's `clock.c`, and not the time page, which only a caller of
`erx_time_page` needs; the page's scale gives the same nanosecond for years of counting at QEMU's and the Raspberry Pi's frequencies, and at most one
above it after that, since `time_table.c` rounds its multiplier up at the largest shift that fits. `erx_fiasco_time_wait_us` takes the remainder, rounds it up to
microseconds and the caller passes `l4_timeout_from_us`, which rounds up again (`__timeout.h:292`), as the receive timeout. So a
wait is never early, and is late by up to Fiasco's timer granularity plus one part in 512. A deadline already past
returns without a kernel call.

### Deletion

#### Thread exit

As in L4Re's libpthread (`join.c:83-87`, `manager.cc:201-214`), a per-task thread deletes the kernel object, because
an exiting thread runs on the stack to be freed and musl's lock word must outlast it.

**Exit.** `erx_thread_exit` puts the thread's record on the reaper's list under the thread lock,
`l4_semaphore_up(reaper)`, and sleeps forever in an IPC wait.

**The reaper's steps, in this order, for each record.**

1. **Delete.** A private `reap(handle)` request runs `l4_task_delete_obj` on the thread and its semaphore. When it
   returns the thread never reaches user mode again, so its stack is free. A refusal ends the machine.
2. **Release.** If the record names a range (a detached thread), `erx_vm_release` it.
3. **Clear.** Store 0 in the record's word to clear and call `erx_umtx_wake(word, 1)`.
4. **Recycle.** Give back the executor's slot, if it has one, and mark the record free. The index is claimed again once
   Fiasco has written its marker.

The first thread exits the same way: its capability is the one the kernel gave it, and its index is never claimed again.

**Join: musl's code stays.** The word to clear is `&__thread_list_lock`, the contract of Linux's exit futex address
(`pthread_create.c:142-146`). `__pthread_exit` holds `__tl_lock`, sets `self->tid` to 0 and unlinks itself, leaving the
lock word holding the old identifier, then wakes the joiner, whose `__tl_sync` (`pthread_join.c:22`) waits on that
word. The tail `for (;;) __syscall(SYS_exit, 0)` lands in `erx_thread_exit`. The joiner returns
only after step 3, and only then calls `__munmap` on the stack (`pthread_join.c:24`). Nothing can create a thread with
the same identifier meanwhile, since `pthread_create` holds that lock across `__clone`. The reaper calls no musl
function, so it cannot wait on the lock it clears.

**Detached.** `__unmapself` (`pthread_create.c:165`) becomes `erx_thread_exit_release(base, size)`, a private `liberx`
entry that puts the range in the record and then does as `erx_thread_exit`.

**Condition variables.** Upstream's `unlock_requeue` wakes the next waiter, instead of requeueing it, for
priority-inheriting and process-shared mutexes. erXos's `unlock_next` (`pthread_cond_timedwait.c`) always does so and
never uses `FUTEX_REQUEUE`, so neither umtx needs a requeue. The cost, one extra wake per waiter, is on
[the performance watch list](todo-performance.md).

#### Task exit

Deleting a task capability does not delete its threads, which the root holds and which keep references to the task
(`task.cpp:686-699`, `thread.cpp:306`). So a task's end starts in one service body, reached by a thread's
`erx_space_stop(ERX_CAP_SELF, status)`, which musl's `exit` does, its creator's `erx_space_stop(task, status)`, a
fault in a task with no fault gate, the destroy of the budget its space was created from, or its parent's exit, and
finishes in a **teardown** that the service carries out a piece at a time between other requests
([The root service](#the-root-service), "The loop"). In the root it is `erx_machine_end`.

The stop's body walks the tree below the task, iteratively and children first, so a space never outlives its parent,
and runs step 1 for each task, a child with the status `ERX_EXIT_PARENT`. The task is then **stopping**: the
teardown runs steps 2 to 4 for each stopping task in the order of their stops, which the row records as a count of
the service's stops, so a child's end finishes before its parent's and the loop posts exit records in the order of
the stops (a space's release finishes its own tree first, and withdraws the records that posts):

1. **The threads.** `l4_task_delete_obj` on each thread of the task, newest first, reaper and dispatcher included.
   Each return means that thread never reaches user mode again (`thread_object.cpp:157-166`). Then its semaphores
   and gate, and its home group, as [Budgets and groups as records](#budgets-and-groups-as-records) deletes one, its
   bind records with it, so each IRQ object bound to it is detached, and one that outlives the task, a
   connection's bell that the domain library created, is left unbound, and a trigger of it waits at the object.
   The row keeps only its place in the tree, the status, the stopper and its stop's count.
2. **The memory, a piece at a time.** Each piece is the last 512 pages of the task's last run, or the whole run
   when it is shorter (`erx_backend_vm_shed_piece`, `liberx/backend/core/vm_table.c`). The service unmaps the
   piece from the task, by the largest flexpages that tile it, and only then releases it in the range table
   (`erx_backend_vm_shed`): its pages return to the pool, each of its mapping records is dropped from its object's
   list, which frees an object whose last reference that was, and a mapping reaching across the piece's start keeps
   its part below. So a page returns to the pool only once no space maps it, and a piece costs its 512 pages of
   addresses, in the root's walk of its page index and in Fiasco's of the task's page tables (`map_util.cpp:866-886`
   visits every entry of a table that exists), and the end of an object whose last mapping it drops.
3. **The objects.** Once the table is empty, the task object, whose deletion unmaps what is left and frees its
   page tables before the call returns (`task.cpp:686-699`). Step 2's unmaps clear entries and free no table
   (`arm/mem_space-arm.cpp:322-341`), so the deletion still walks every entry of the tables the task touched
   before it frees them (`arm/mem_space-arm.cpp:346-356`), which makes this the teardown's longest piece; then
   the handle table is emptied, each entry dropping its object's count, and freed with its runs, and every object
   the task created goes, as the [object table](#shared-objects-and-the-jit-alias)'s third row says, its mappings
   in other tasks revoked first.
   The objects the task created and those whose last entry this drops are only marked here: the service ends the
   marked objects once the piece is over, before it answers or receives, so an end that stops further spaces, a
   budget's included, never runs inside another task's end.
4. **The status.** The exit record, an `erx_fault` of kind `exit` with the first stop's status, goes to the space's
   fault gate ([Fault gates](#fault-gates)), after step 3, so it comes only once no thread of the space can run and
   its memory is back: a creator that restarts a domain on its record finds the pages it needs. A test task, which
   has no fault gate, gives its status as a test's transcript line: the end ups a semaphore of the root's, and the
   launcher's `erx_fiasco_task_join` asks the service, which answers `ERX_EBUSY` with the task's index while the
   space runs or stops, so the stub waits on that semaphore and asks again; the second answer takes the status,
   deletes the space with every space below it, freeing their labels, and closes the root's handle. A space that
   held the last handle of the budget it is charged to goes with that budget once its stop is over, and as every
   deletion does, the deletion withdraws its exit record: its creator sees no record, and a join answers
   `ERX_ESTALE`. A thread that stopped its own task is answered `ERX_OK`, an answer it never sees, since the stop deleted it.

**A space's release finishes its teardown.** The end of a space record, by its last handle's close, its creator's
destroy or end, or its budget's destroy, stops the space if it runs and then runs the teardown of the space and of
the spaces below it, which stopped before it, in that body, before it deletes them all; another space's pending
teardown waits for the loop. So a budget's end returns its guarantee only with its spaces' pages back in the
pool, and a deleted row is never a stopping one.

**A request cannot race this.** The service runs each request, fault and piece to completion before it receives the
next, finds the task from the gate's label and each handle in that task's table, and keeps no pointer across a
receive. Fiasco IPC queues no messages: a request is a live thread blocked on the gate, and deleting the thread
removes it. So once a stop returns to the receive, no request or fault comes from that task, and no call reaches it:
the decoder drops a label naming no live task, a stopping space is no call's target (`ERX_EINVAL`), takes no child
and is not stopped again, a join answers `ERX_EBUSY`, and the stopping task's handles and objects stay as they
were until step 3, which ends them in one piece. Its label is reusable once its exit record or status is taken.
A space handle is an entry of the creator's table and names the stopped space's record until the creator
closes it, which frees the record; the root frees no entry before its holder's close, and a close advances the entry's generation
([Handles](#handles)), so the handle never names a later space.

### musl over the backend

`ARCH=erxos` layers on `arch/aarch64`: `arch/erxos/arch.mak` names it as `ARCH_CPU`, so the CPU's headers and assembly
stay, and a file under an `erxos` directory replaces both the CPU's and the generic file of its name. Every system
call site lands in `__erx_syscall` (`src/internal/erxos/syscall.c`), one switch onto `liberx`. `tools/lib/erx/musl.rb`
refuses a build in which a CPU source that traps has no replacement, and the chokepoint rules read the `erxos` directories, so only
`liberx` reaches the kernel. The switch is the current form behind [the C library seam](design-runtime.md#the-c-library-seam), whose target deletes
the `SYS_` names, so that a call not ported fails at link rather than at run time.

| Call | Over | Limit |
| --- | --- | --- |
| `futex` wait and wake | `erx_umtx_wait`, `erx_umtx_wake` | no priority inheritance: its probe reads `ENOSYS` |
| `mmap`, `mprotect`, `munmap` | `erx_vm_reserve`, `erx_space_protect`, which commits what it makes accessible, `erx_vm_release` | anonymous memory, and in a program a `mem` descriptor and the checks against its range through the descriptor row below; another descriptor `ENOSYS`; no type `EINVAL`; a flag other than the type, `MAP_ANONYMOUS`, `MAP_FIXED`, `MAP_NORESERVE` and `MAP_STACK` `EOPNOTSUPP`; write and execute together is `EACCES` |
| `brk` | reports no room | mallocng uses `mmap` alone |
| `__clone` | `erx_thread_create`, `erx_fiasco_thread_set_clear_word`, `erx_thread_start` | only `CLONE_THREAD`; a worker, or an executor with `ERX_CLONE_EXECUTOR`, which only `erx_pthread_create_executor` causes |
| `exit`, `__unmapself` | `erx_thread_exit`, `erx_thread_exit_release` | |
| `exit_group` | `erx_space_stop(ERX_CAP_SELF, status)` | whoever started the program reads the status's low byte; in the root the stop is `erx_machine_end` |
| `clock_gettime`, `nanosleep`, `clock_nanosleep` with no flags | `erx_fiasco_clock_ns` for `CLOCK_MONOTONIC`, `erx_time_wall_ns` for `CLOCK_REALTIME`, a timed umtx wait | `CLOCK_REALTIME` is the time page's wall clock, the clock from boot plus the offset the clock service sets ([design-time.md](design-time.md)); `EOVERFLOW` when the page's sequence has run out |
| `sched_setaffinity` | `erx_thread_set_affinity` | a mask's first word |
| `sched_getaffinity`, `prctl` | not offered: `ENOSYS` | so `sysconf(_SC_NPROCESSORS_*)` answers musl's default of 1 in any program, and `pthread_setname_np` on the caller fails, which ERTS ignores; ERTS counts CPUs from the boot information page |
| `write`, `writev` to 1 and 2, `ioctl` `TIOCGWINSZ` on them | `erx_fiasco_libc_write`: the root's (`libc_root_write.c`, alone in its file so that musl's reference pulls in the log's line path and not the start path) and a domain's runtime's as debug log records through `output_line.c`, a test task's through the service ([The console](#the-console)) | a runtime's lines are logged as records of its space, a test task's bytes go out unchanged; in the root and in a task other descriptors are `EBADF`; the size reads zero, which keeps stdio line buffered |
| every call of a program but a closed list that names no descriptor: the descriptor calls, `mmap` of a descriptor, `PROT_EXEC` in `mmap` and `mprotect`, and the range checks of `munmap` and of `mmap` with `MAP_FIXED` | the program layer's descriptor table, through a seam function that every build's entry file defines beside `erx_fiasco_libc_write` (`libc_root_write.c`, `libc_task.c`, `domain_entry.c`, `program_task.c`), so a build without it fails to link; musl's syscall switch (`syscall.c`) offers the seam every call first, and only a program's (`program_task.c`) takes one, handing back the closed list of calls that name no descriptor to the rows above, the others answering that they hold no descriptor; musl's `fstatat` reads `SYS_fstat` into the kernel's `struct kstat` layout, so `syscall.c` hands the seam a `struct stat` and copies its answer into that layout ([design-programs.md](design-programs.md#the-posix-lite-personality)) | the table answers each call on a descriptor it holds, with `ENOSYS` for what it does not implement, a call it lists as naming a descriptor, on one it does not hold, with `EBADF`, `PROT_EXEC` with `ENOTSUP`, since only the loader maps code, and any other call with `ENOSYS`: a program's seam takes every call that names a descriptor, so nothing a program does reaches the console row above, and a program writes only to the descriptors its session installed, its standard output and error among them, as pipe ends ([design-pipes.md](design-pipes.md#inherited-ends)) or opens of a terminal ([design-programs.md](design-programs.md#descriptors-and-files)); the root and a task are offered only the console `write`, `writev` and `ioctl` row above, and the others are `ENOSYS` there |
| `set_tid_address`, `gettid` | `erx_fiasco_thread_set_clear_word`, the index plus one | |
| `getpid`, `getppid`, the user and group identifiers | in a program, the startup message's `pid`, `ppid` and `uid`, from `liberx`'s record of the program's start ([design-programs.md](design-programs.md#the-startup-message)); elsewhere 1, 0 and 0 | the root and a task that is no program have no process id and no user, so each reads the same fixed values |
| `sched_yield` | `erx_yield` | |
| `getrandom` | `erx_entropy_take`, at most 256 bytes a read | the whole length or a failure, never a short count: a read the generator does not complete fails the call with `EIO` and leaves zeros where the call wrote; `GRND_NONBLOCK`, `GRND_RANDOM` and `GRND_INSECURE` change nothing, since the generator never waits to be seeded, another flag is `EINVAL`, as FreeBSD's `sys_getrandom.c` refuses it, and so is a length past `SSIZE_MAX`, which the count returned could not hold; musl's `getentropy` over it keeps its own 256-byte limit, `EIO` past it |
| `set_robust_list`, `get_robust_list` | the calling thread's list head, kept in musl's `struct pthread` | kept and never walked: musl walks the list itself at thread exit, and only a task's death would need a kernel's help; a size other than Linux's three-word head is `EINVAL`; another thread's list is not offered: `ENOSYS` |
| `rt_sigprocmask`, `tkill` of `SIGCANCEL` | answered with no effect | the signal mask reads empty |

Everything else is `ENOSYS` in the root and in a task; a program's descriptor rows above are the program layer's. No signal is delivered, so `pthread_cancel` returns 0 and acts at the target's next
cancellation point rather than interrupting a call it is blocked in.

`liberx/backend/fiasco/libc_start.c` calls `__libc_start_main` with one argument, no environment and an auxiliary
vector of the ELF headers, which `root.ld` and `task.ld` load first so that musl finds the TLS image, the page size, the
CPU feature words as `AT_HWCAP` and `AT_HWCAP2`, and `AT_RANDOM`. The feature words are the boot information page's in
a runtime's root or domain, a program's are its session's from the registers `program_arg`'s `hwcap` and `hwcap2` name,
and 0 where an entry has neither. `AT_RANDOM` names 16 bytes of one
`erx_entropy_take`, kept in the start block for the program's life, from which musl takes its stack guard and mallocng
its secret; a start whose generator refuses them never runs the program, and stops the task with
`ERX_FIASCO_TASK_STATUS_ENTROPY` or, in the root, says so and ends the machine. The vector's keys are `abi/formats/elf64.txt`'s,
which a host test checks against musl's `elf.h`. On a root, `libc_root_start.c` first moves off the image's
64 KiB start stack onto 1 MiB from the pool, with a reserved page below it that nothing commits, so an overrun that touches
that page faults instead of overwriting `.bss`, and it ends the machine if the start comes back. A test's root that has no
archive brings the service up in `libc_root.c`, and the system's root in `root.c`. `libc_task.c` is a task's `erx_task_main`,
whose thread `task_start.c` has readied, and it runs on the stack `task_start.c` gave it. A program's own thread handle is its index in the root and in a task alike, so the seam is one file for both.
The program links with `libl4sys.p.a`, which defines four symbols and needs none, and with LLVM compiler-rt's builtins
(`tools/lib/erx/compiler_rt.rb`) for binary128 arithmetic.

#### musl's own tests

`tools/lib/erx/libc_test.rb` builds `libc-test`, fetched at its pinned commit, against this musl: each test of
`functional`, `regression`, `math` and `musl` becomes a program for the boot image, and `test/guest/native_libc_test`'s root
runs every one as a task, one after another, many to a boot, since a task's fault leaves the machine running. It
joins each with `erx_fiasco_task_join_until` and stops one still running at its deadline. A test's exit status is its
result. What it prints reaches the serial log as the program wrote it, so triage can read it. The root's lines lie between a test's
output: the root opens each `end` line with a newline, so output with no final newline stays on its own line and the result stays
whole, and the `run` line after it starts a line too.

Test programs are trusted, and the runner's reading has that limit. A program can print a line of the root's form, and a boot
says no more than its log. The last `end` line for a name counts, so the root's line outweighs one the test printed before it. A printed
`end` that nothing of the root's for that name follows stands as that test's result: one for a test the boot stopped during, or one naming
an earlier test of the same boot. Nothing escapes a program's output to prevent that.

A test whose own object calls what Phase 1 does not offer (files, processes, signals, sockets, shared objects) is not
run, and its result names the calls. Every test ends with one result in `build/libc-test`, never in the tree: passed, failed with its
exit status, its fault or its build error, timed out, not run with its cause, or unknown. A test the root did not reach is
not run, and how the one under way when a boot stopped went is unknown, with what stopped it named. Only the end
line of that boot says how a test ended: `tools/erx check-libc-test ACCEL CPUS` relinks every program and deletes each
boot's old log first.

Every test that does not pass has its verdict in `test/conformance/libc-test-verdicts.txt`, one line each: the result it must
have, and why; a failed line also pins the places in libc-test's source that the test's error lines name. The reason is a difference this document states, musl's own behaviour with its source cited, a bug with its
`TODO.md` item, or, for a test not run, the cause the plan names. A test the table does not name must pass.
`check-libc-test` fails on any result that differs from its line, a failed test that reports a place its line does not
list, a test not run for another cause than its line's, a line naming no test, a boot that leaks the pool, and a boot that
never says whether it did, so a test that starts to pass needs its line removed. The backend's
differences are the two cancellation tests, which no signal interrupts, and the priority-inheritance tests, whose futex
probe reads `ENOSYS`; the oom tests need `RLIMIT_DATA` through `t_memfill`, and are not run.

## Interrupts and readiness

A group's readiness lives in its **home task**, the task its threads run in ([Budgets and groups as
records](#budgets-and-groups-as-records)): the task's one **park record** holds executor slots, status page, park
lock, parked list, ready list and listed flags, and the task's **label page**, committed with the task right after its
thread table at a constant address, holds for each of the group's 64 entries the label `erx_group_take_ready` returns. The executors that park on it, the semaphores they wait on and the
dispatcher that triggers it are all the home task's, so the park protocol below runs inside one task, as it does in the
root.

* **The dispatcher** blocks in `l4_ipc_wait`. Every message is one IRQ object firing, whose Fiasco label names an entry of the
  task's home group. It runs a trigger for that entry and waits again, at the band's base, for a doorbell and for a line bound
  to the group alike. An object bound to a thread does not pass through it: Fiasco delivers that object to the thread's own
  wait ([Urgency](#urgency), "A bind to a thread"). So a doorbell's ringer, whoever it is, makes only base-level work
  ([Urgency](#urgency), "What reaches the urgent level"). The task's own backend initialisation creates the
  dispatcher, and its creation tells the service the thread's index.
* **A bind** to a group is a service body. The service, which alone knows which of a group's entries are in use, gives
  the IRQ object a free one, stores the caller's label into it through the window with a release store, which the
  home task loads with acquire order, and only then runs `l4_rcv_ep_bind_thread(irq, dispatcher,
  entry)`, so a delivery never reaches an entry before its label. When the group has no home yet, or its home task has
  no dispatcher yet, as when the domain library binds a domain's bell before the domain's first thread runs, the
  service records the bind and makes it when the first thread fixes the home or the dispatcher registers, whichever
  is later; a software fire before then arrives at the bind, which is Fiasco's behaviour for a detached object. A
  bind record, pending or made, is kept with its object, names the group and goes with the group, whether its home task ends, its
  budget is destroyed or it never gets a thread, and the object's own destroy detaches it and frees its entry. A
  bind of a bound object to the same group moves its label, as `erx_device` does when a new process takes a line; to
  another group it is `ERX_ENOTSUP`. An unbind (`ERX_CAP_NULL`) detaches the object and frees its entry, as
  `erx_device` does when a line's process exits, and an object an unbind or a group's end left unbound may be bound
  again. The root binds and unbinds an object in any group it holds, as the domain library does a domain's bell and
  the root's own drivers their lines; another task holding the object binds, moves and unbinds it only within the group it is the home of, so that a
  holder's driver binds the line it was given to its own group ([Device records](#device-records)), and within a group it
  created, so that a session binds a program's doorbell into the program's group, whose home is the program
  ([design-programs.md](design-programs.md#the-channel)). A group's home is its creator or a space below it, since
  group handles pass only down and a thread is created only in its caller's own space or one the caller created. A group the task neither created nor is the home of, as the target or as the group the
  object is bound to, is `ERX_ETYPE`. A delivery already listed
  under an entry that is then reused reaches its new sink as one look, which every sink treats as a hint
  ([design-domains.md](design-domains.md#connections)).
* **A trigger and an ack** are the holder's own `l4_irq_trigger` and `l4_irq_unmask` on the capability the root
  placed in its task, without Fiasco's special right, so a holder triggers and acknowledges but never binds or
  detaches (`irq.cpp:1104-1137`); the doorbell reaches the dispatcher with no service request
  ([Who holds what](#who-holds-what)).
* **The ready list** is an array in firing order, which a take shifts down. It has one entry per bound object, of at most 64, and an object is on it at most once, by its listed flag, so it
  cannot overflow and a trigger allocates nothing. A fire the dispatcher has not received yet is one delivery however often it
  repeats (`Irq_sender::queue`, `irq.cpp:984`), which the listed flag would report as one anyway. That bounds the pending
  state, not the recipient's work: Fiasco clears the queued state when a delivery finishes (`Irq_sender::finish_send`,
  `irq.cpp:751-755`), so the next fire is a new delivery, and the park core's trigger wakes the longest-parked executor even
  for an object already listed (`ERX_BACKEND_PARK_OP_SIGNAL`, `liberx/backend/core/park_table.c:108-115`). A ringer that keeps
  firing therefore costs the recipient one dispatcher run and up to one executor wake per delivery, at the recipient's base level,
  however rarely the recipient takes its readiness (FD31).
* **`erx_group_take_ready(max)`** drains up to `max` entries, at most `ERX_MSG_WORDS`, under the park lock, clears their flags
  and mirrors `ready`.
* **Ack.** A device line stays masked from delivery until `erx_irq_ack`, Fiasco's own behaviour for a bound level IRQ object
  (`irq.cpp:1013-1037`). A software object has no line to mask, so its ack does nothing, and the ack of an object not yet bound does nothing either, since
  its bind is what opens it.

### The park protocol

The protocol of [design-scheduler.md](design-scheduler.md) is kept, with a semaphore per thread, as L4Re's pthread has
(`restart.h:26-37`), in place of the kernel's switch. The operations are one pure state machine, `park_step`, over the
group's epoch, each slot's epoch, the parked list in order, the ready list and the listed flags. It reads no clock, makes no
Fiasco call, and returns what the caller does after unlocking.

| Operation | Under the park lock | After the lock |
| --- | --- | --- |
| **Trigger**(object), by the dispatcher | list the object unless listed; mirror `ready`; advance the group's epoch and mirror it; take the longest-parked slot, if any | up that slot's semaphore |
| **Park**(slot, g, s) | if the group's epoch differs from `g` or the slot's from `s`, return `ERX_OK`; otherwise join the parked list | `l4_semaphore_down` with the deadline |
| **Timeout**(slot) | if still on the list, leave it and return `ERX_ETIMEDOUT`; if taken off, return "owed" | if owed, an unbounded `l4_semaphore_down`, then `ERX_OK` |
| **Wake**(slot) | advance the slot's epoch and mirror it; if on the list, take it off | if it was taken off, up its semaphore |
| **Release**(slot), an executor's death | free the slot; advance the group's epoch and mirror it; take the longest-parked slot, if any | up that slot's semaphore |

The executor reads the epochs before its empty check. A trigger or wake before the park changes an epoch, so the park returns at
once; one after it finds the slot on the list. With no slot parked, a running executor finds the work at its next safe point.

The epochs and `parked` are mirrored in the group's status page, the layout `erx_group_stat` of `abi/kernel.txt`, under the park lock,
with each slot's `epoch` and `state`; its other fields stay 0, which `erx_group_info` reports as `unsupported`. A slot taken off the list
is owed exactly one up, and the semaphore is the one the thread's umtx waits use, which holds 0 whenever the thread enters either wait.

### The trace ring

`erx:trace` lines up ERTS's scheduling with the parks, wakes and IRQ deliveries the backend carries out
([Tracing](design-live.md#tracing)). The root keeps one ring of 4,096 `erx_trace_record` records, the layout and events of the
kernel's rings ([Trace ring](design-kernel.md#trace-ring)), so erXos's kernel adds a source and not a format. The ring is static in
`liberx/backend/core/trace_ring.c`, with a head word holding the next index, and backend initialisation touches its pages, so
no write faults. That file is linked only into the root and the hosted process; a task links a stub whose reader answers
`ERX_ENOTSUP` and whose writes do nothing, so a task has no ring.

| Event | Written by, and when | Arguments |
| --- | --- | --- |
| `park` | an executor of the root, after releasing the park lock, when **Park** joined the parked list, before `l4_semaphore_down` | `slot`, `deadline` |
| `wake` | the same executor, when its park ends: woken, timed out, or after the owed down of a timeout that found it taken off | `slot`, `result` |
| `irq_deliver` | the root's dispatcher, for each delivery, before its **Trigger** | `label` |
| `space_start` | the service, when `erx_space_create` makes a task | `target` |
| `space_end` | the service, at [task exit](#task-exit) | `target`, `status` |

The executor writes both records of its own park, so its `wake` follows its `park` in the ring by program order; a park
that returns at once writes neither. A trigger between the release of the park lock and the `park` record puts its
`irq_deliver` before the `park` it ends; the park protocol is not affected, and the timeline shows the records in the
order they were written. `thread` and `space` are the writer's thread record index and task index, and `target` the
task's index, each plus one so that 0 stays "none"; indices are reused, so on this ring they name a thread or task only
within its life. `cpu` is the one CPU the writer's affinity mask names, where Fiasco must place it
(`scheduler.cpp:96-103`); with any other mask the backend does not know the CPU and the record sets `cpu_unknown`. Only
the root's threads write, so a test task's parks are absent.

**Writing.** Under the trace lock the writer reads `erx_clock_ns`, takes index `i` from the head, and follows
[Sequence-counted records](design-kernel.md#sequence-counted-records): it stores `seq` as `2i + 1`, each field with release
order, then `seq` as `2i + 2` and the head as `i + 1`, each with release order. The clock is read under the lock, so the
ring is in time order. A writer whose `2i + 2` would pass the sequence's terminal value writes nothing, and the ring is
exhausted.

**Reading.** `erx_backend_trace_read(cursor, records, max, result)` takes no lock, so no writer waits for a reader. It reads
the head with acquire order. A cursor of `UINT64_MAX` copies nothing and returns the head as the next cursor, so a trace
starts at the present; any other cursor past the head, or `max` of 0 or over 512, is `ERX_EINVAL`, and a cursor at the
head of an exhausted ring is `ERX_ELIMIT`. A cursor more than 4,096 below the head moves up to the head less 4,096, and
the records it skips count as overwritten. For each index `i` from there to the head, at most `max`, it loads `seq`,
each field and `seq` again, all with acquire order, and keeps the copy only if both loads are `2i + 2`, counting any
other as overwritten. It writes only within `records`, copies the event as stored, and returns the next cursor, the
number kept and the number overwritten. Its caller is the BIF `erx_trace_ring:read/3` ([Tracing](design-live.md#tracing)).
The hosted backend keeps the same ring and writes the parks, wakes and deliveries it carries out, each with
`cpu_unknown`.

**Reporters.** The ring's records carry the backend reporter `liberx_trace`, declared in `abi/inspection.txt` as standing in
for the kernel and labelled `liberx trace`. `erx_trace_read`, the kernel's call, is refused, so the trace's `kernel` row and
the inspector's `[kernel, trace]` are `unsupported`, reported by `kernel`.

## IPC gates and where transfer fits

Fiasco IPC is the backend's own transport for requests, faults and IRQ delivery, and carries nothing above `liberx`. Above it,
three things cross between tasks, and each is a row the service implements over tables it alone owns:

* **Memory.** Every page two tasks share is a memory object some task created, which the service maps with `l4_task_map` from
  its own window into each task that maps it ([Sharing memory between tasks](#sharing-memory-between-tasks)). A connection's
  lanes, a channel, a pipe and a device's buffers are such objects, and nothing else is shared.
* **Doorbells.** An IRQ object any task created, bound to a group in its home task and triggered through the service by any
  task that holds it ([Interrupts and readiness](#interrupts-and-readiness)).
* **Handles**, passed by `erx_cap_pass` from the caller's own table into a space it created, the creator's case
  ([Passing a handle](#passing-a-handle)), and **records**, the faults and exits of a space, queued at the gate its creator
  named ([Fault gates](#fault-gates)).

No gate carries a message, and nothing passes at a rendezvous: no consumer needs either, since domains share only connections
([design-domains.md](design-domains.md#connections)) and a program reaches its session only through its channel
([design-programs.md](design-programs.md#the-channel)). This is `moe`'s shape, not a second kernel: `moe` hands its clients
dataspace capabilities and maps their pages into the clients' tasks, and the service implements only the table's rows.

### The root service

**One gate per task**, all bound to the service thread, each made with `l4_factory_create_gate(factory, gate, service_thread,
task_index << 2)`. The receive gives the label, with the sender's rights in its low bits (`ipc_gate.cpp:504`), so the decoder masks
them and the rest names the calling task. A task names other objects only by handles in its own table, and spaces only by
`ERX_CAP_SELF` or the handles of spaces it created. The root's own threads call through the root's gate.

**The wire**, in the native UTCB's message registers, is `enum fiasco_call` and the request layouts of
`abi/erx_abi.txt`, with a hand-written word-count table over their `sizeof` in `service_wire.c` and no emitter of
its own. It is this backend's internal wire, not a seam: no number or layout reaches a caller of the function API,
and erXos's kernel has none of it, so [Transport](#transport) records it as a difference and not as ABI to keep.

| Message | Tag label | Words |
| --- | --- | --- |
| request | its `fiasco_call` number | `mr[0]` the caller's thread index; `mr[1..]` the rest of the request's layout |
| reply | zero | `erx_fiasco_reply`: `mr[0]` the status; `mr[1]` to `mr[4]` the results |
| fault | Fiasco's negative `L4_PROTO_PAGE_FAULT` or `L4_PROTO_EXCEPTION` | as Fiasco sends them |

**Payloads never cross the native UTCB.** What the ABI puts in the caller's UTCB (the bytes of `erx_debug_log` and of a task's `task_write`, up to
`utcb_bytes_max`; starting registers; results larger than the registers) stays in the caller's public UTCB, which the service reads
and writes through the window, by the index in `mr[0]`. So 63 message words are always enough. The ABI's memory windows are reached
through the object's window addresses. The caller's task can write its public UTCB while the service reads it, so the decoder
copies what a request takes from it, the length first and then at most that many bytes, into the service's own buffer once, and
every check and the body read only that copy; nothing is read from the public UTCB a second time for the same request.

**The loop.** `l4_ipc_wait_ext` into one of the service's reply slots; decode; run the body; run one piece of a pending teardown; end what the body and the piece marked; empty the reply slot of every fault whose task has stopped; `l4_ipc_reply_and_wait_ext` from the slot the message came in and into the same slot, with `L4_IPC_SEND_TIMEOUT_0`, or with `L4_IPC_BOTH_TIMEOUT_0` while a teardown is pending. A body never calls a stub, and never hashes an image entry: the root's caller checks one in its own thread first ([The call table](#the-call-table), `erx_image_map`), because a hash a whole image long would hold every other call of every task and of the root behind it. For the same reason a stopped task's teardown is no body but pieces ([Task exit](#task-exit)): the stopping tasks are the service's pending work, taken in the order of their stops, and while any is pending every receive has a zero timeout, and one that finds no message yields the CPU to the ready threads of the service's priority, the base level, which the configured domains' ordinary work shares ([Bands](#bands)), before the next piece. So a call waits behind at most one piece, the longest of which is the task object's deletion, unless it comes behind a space's release or a budget's destroy, which finish the teardown of the spaces they delete in their own body. A body that stays long holds every call all the same, and a root thread that waits on it holds what it runs: on the root's normal scheduler, the watchdog pet ([The watchdog](#the-watchdog)). So the NIFs a runtime calls all through its life whose call is a service round trip, `erx_log`'s three calls, `erx_object_info`'s report and `erx_clock_nif`'s setter, are dirty I/O NIFs in every domain's runtime, and the domain library's entries are dirty CPU NIFs.

**Reply slots.** The service receives into Fiasco's explicit reply slots (`EXPLICIT_REPLY_CAPS`, a reply space charged to the
root's quota), so that no receive fills a slot that still holds a caller: Fiasco answers such a receive by emptying the slot and
printing `Application bug: reply capability overwritten!` (`receiver.cpp`, `set_reply_cap`), which after the handoff reaches
the log as a kernel record ([The kernel's lines](#the-kernels-lines)) and which the harness fails a boot on. Every message but a fault is answered from the slot it came in, and the next receive
fills that slot again. A fault's slot is parked with its task and the receive moves to a free slot (`reply_slots.c`). Once the
task is no longer live, its stop has deleted the faulting thread, and the service answers the parked slot with an empty message,
which resumes nothing and frees the slot. The table has 64 slots, one for each faulting thread whose space's server has not
stopped it yet; with all but the receive slot parked, a further fault is not parked, and the next receive takes its slot over
with Fiasco's warning while its thread stays blocked until its stop. The table is the root's alone and no domain's
limit bounds it, unlike the pause's held exceptions ([Threads, bands and stops](#threads-bands-and-stops)), which take
slots of the same reply space within the domain's share; a fault names no thread, so its slot cannot be the thread's.

**Refusals.** A label naming no live task is dropped with a counted diagnostic and answered `ERX_EDEAD`, an answer no running
thread sees: a task that is no longer live has had its threads deleted. An unknown call number, a word count
that differs from the ABI's, a thread index past the table or a payload length past `utcb_bytes_max` is `ERX_EINVAL`; a call without a
row is `ERX_ENOTSUP`. The decoder has a fuzz target. Addresses cross as values, and the service never loads through them.

### Spaces, parents and exit records

`erx_space_create`, from any task, makes a task and a **space record**: its budget, its parent, its fault gate, its label, its
flags, its handle table of `cap_limit` entries, its list of children, and its domain row and band, its creator's
([Bands](#bands)); the domain library's `erx_space_create_domain` makes a domain's space with a domain row of its own. In 1b-A the parent is the root's own space, and from 1b-B, where sessions make sub-spaces, it is the caller's own space or a space the
caller created, so the records form the tree of [design-kernel.md](design-kernel.md#creating-spaces): the system domain's
space at the root, every domain below it, a session's anchors and images below the session. The creator then builds the space
with the calls that serve its own: it reserves and maps in it, maps image entries and slices into it, passes it handles,
creates its first thread in a group it holds and starts it ([design-system.md](design-system.md#creating-a-domain),
[design-programs.md](design-programs.md#starting-a-program)).

A space ends by [task exit](#task-exit), which ends every space below it first, so no program outlives its session and no
sub-space its domain. Its exit record goes to its fault gate once every thread of it is deleted, carrying the first stop's
status: the status of `erx_space_stop`, `ERX_EXIT_PARENT` for a space its parent's end stopped, `ERX_EXIT_CRASH` for one
whose fault gate's server stopped it after a fault and named that status. The label is the one its creator gave, all 64
bits, recorded as given and neither checked nor required to be unique, as on erXos's kernel. The domain
library turns a domain's record into `{domain_down, D, Info}` and a session's port driver turns a program's into its exit
status, as on erXos's kernel ([design-system.md](design-system.md#ending-a-domain),
[design-programs.md](design-programs.md#a-programs-end)).

### Fault gates

A gate is a record with the thread bound to it, a queue of records, and the list of spaces that name it. It carries records
and nothing else: the faults of its spaces' threads and their spaces' exit records, each an `erx_fault`, which is how a
creator sees every end below it. Every queue entry lives in the record it names, a fault in its thread's record and an
exit in its space's, and the queue links them by index, so posting allocates nothing and a gate holds at most one record
per thread and one per space it serves. Fiasco's fault message names only the task, so a fault's entry
comes from a pool belonging to the space and its record's thread is `unknown`; a task that reaps a faulted thread and
faults again can run its own pool out and lose its own records, and only that task is harmed (FD20).

* **The receiver.** Every record goes to the one thread bound to the gate, the domain library's fault thread for every
  domain's gate and a session's gate worker for its programs'. A gate with no thread bound keeps its queue, and the thread
  a later bind names takes the records in order; a bind replaces the thread, and the deletion of the bound thread leaves
  the gate unbound with its queue kept. A fault record names the space and not the thread, whose field is `unknown`
  ([Faults](#faults-and-the-fault-of-the-root-task)).
* **Posting.** The service appends the record to the gate's queue and, if the bound thread is listed as waiting, takes it off
  the list and runs `l4_semaphore_up` on its semaphore.
* **`erx_ipc_wait(wait_by)`.** The stub asks the service for the oldest record of any gate bound to the calling thread. If
  there is one, the service copies it into the caller's public UTCB and removes it, and the stub returns its label and the
  tag of a message from the kernel, an `erx_fault_t`'s words and no items; otherwise it lists the thread as waiting
  and the stub runs `l4_semaphore_down` with the deadline, then asks again. On a timeout the stub asks the service to take
  it off the list; a thread already taken off is owed the up that posting sent, and the stub absorbs it with an unbounded
  down before it returns `ERX_ETIMEDOUT`. This is [the umtx table](#the-umtx-table)'s invariant: a thread taken off a list
  is owed exactly one up, and only such a thread is.
* **Withdrawal.** A space's deletion withdraws its queued records, which on Fiasco happens at `erx_fiasco_task_join`,
  at the release of its space record (its last handle's close, or its creator's destroy or end), at the deletion of a
  space above it, or at a failed create, and not at the stop; a gate's destroy drops its queue and leaves its spaces
  with no fault gate, as on erXos's kernel: their later records are dropped and counted in the space's `dropped` counter, which the inspector reads, a thread that
  faults then stays blocked, and the space's other threads run on until its creator stops it. No Phase 1b caller reaches
  that state while a space lives: the domain library's gates last as long as the system domain, and a session's gate goes
  only with the session's task, whose end stops its programs first. A child stopped by its parent's end posts its exit
  record to the parent's gate, which the same walk then deletes; the record goes with the gate, since its reader is gone.

A space created with `ERX_CAP_NULL` as its fault gate, which only the test-task launcher's `test_space_create` may make, has its fault end it at once
with a crash record through `l4_vcon_write`, and its status reaches the launcher's join, as below.

### Passing a handle

`erx_cap_pass(from, to, n)` is carried in its creator's case only: `from` is the caller's own space and `to` a space the
caller created. The domain library so gives a domain its budget, groups, connection sides and bells, time page, release slice
and devices (`erx_dom_install`), and a session gives a program its budget, group, channel, data area, code objects and pipe
ends. The caller is any task: a space's handle is in its creator's table alone, since none passes, so `to` names a
space the caller created. The body takes the
`n` items, at most `ERX_MSG_CAPS`, in order. They are `erx_msg_item_t` in the caller's public UTCB, as on erXos's
kernel: a descriptor holding the item's rights mask and its move bit, and the handle, copied once and read only there.
For each item the body checks the descriptor (any other bit set is `ERX_EINVAL`, and a type it names, which makes a
checked pass, `ERX_ENOTSUP`), the handle and its kind, and room in
`to`'s table. It then makes an entry in `to`'s table ([Handles](#handles)). The new entry gets the rights of the
caller's entry intersected with the mask, less `DESTROY`, since only an object's creator destroys it here. For an IRQ
object, the one kind placed with a capability ([Who holds what](#who-holds-what)), the pass then calls the one
placement function of [Handles](#handles) on the new entry, which maps the root's capability into the entry's IRQ slot
in `to`, with `L4_CAP_FPAGE_RO`, only when the entry's rights hold `TRIGGER` or `ACK`, and maps nothing otherwise.
Every other kind is the entry alone. No
pass set applies: as on
erXos's kernel, a type's pass set binds a pass between peers and a fork's copy, not a creator's pass into a space it
created ([design-kernel.md](design-kernel.md#passing-capabilities)), and that is the only pass this backend offers, so the
creator's mask alone narrows what the holder gets. It rewrites the item in the caller's UTCB
with the new entry's value in `to`, its type and the entry's rights. So rights only shrink, in what the call reports and
in the entry every service use checks, as on erXos's kernel. At the first item it refuses it stops and
returns that item's error, leaving the items before it passed; the caller undoes them, the domain library by
destroying the budget the creation was charged to, as a session does with a program's (FD4). A copy makes a second
entry, which raises the object's count of holders; a move is a copy and then a close of the
caller's entry. erXos's kernel checks every item before any moves, so a refused pass moves nothing there.

What it leaves out, each refused with `ERX_ENOTSUP`, has no consumer: a pass from a space other than the caller's own, a
pass into the caller's own space, and a pass of a space or gate handle. A budget or a group handle passes, for the
domain library's install; a task that holds a budget's last handle ends that budget after its own end, not inside it
([task exit](#task-exit)), so the sweeps above never meet a space whose end is under way. A thread handle is no entry of the table ([Thread creation](#thread-creation)),
so the body reads an item only as an entry of the caller's table and never passes a thread. These are the passes through which a handle
could reach a task that is not below the object's creator, so leaving them out is what keeps
[handles flowing down](#erxos-on-fiasco), and with it the safety of deleting an object at any moment; a row that
passes at a rendezvous would let a handle reach a task outside the creator's tree, and that argument would have to be made
again.

**Every use checks the passed rights.** The rights an item comes back with are its new entry's, and every service
operation that names the handle checks the right it needs against that record before it acts, whatever the holder's
`liberx` asks: a write mapping needs `WRITE` (`ERX_ERIGHTS`, so a party passed its peer's side without write maps it
read-only or not at all); a bind needs `BIND`, which the domain library's and a session's masks leave out of every
doorbell they pass to a peer and keep on a device line they pass to its holder, and Fiasco's own `sys_bind` refuses the
holder's capability either way, since it lacks the special right, so only the root binds; a charge to a budget needs `ALLOC`, and a space
created under it `SPACES`; a thread attached to a group needs `ATTACH`; and a destroy needs the creator's own slot,
since no pass conveys `DESTROY`. The domain library's and a session's masks are therefore enforced by
the root, not kept by the holder's discipline, and a domain that bypasses `liberx` with raw requests is held to them
alike.

### Sharing memory between tasks

A connection is the domain library's four objects, two sides and two bells, created under the connection's child budget,
the bells bound by the library to each party's group, and passed to each party, which maps its sides itself
([design-domains.md](design-domains.md#connections)); on this backend each of those steps is a row above, and the lane
layout and wake handshake are the runtimes' own. A channel and a pipe are the same pattern inside a session's tree, and a
device's register window and contiguous memory the same pattern for its holder.

**Who maps.** The party that uses a mapping asks for it: each runtime's `liberx` maps the sides of each connection it is
introduced to, a program's
`liberx` its channel and pipe ends, a driver its device's window, each into its own space with `erx_vm_map`; a creator maps
into a space it created only while building it, as the domain library maps a domain's boot information page and a session a
program's image and data area. The service performs every map at the rights the caller asks, beneath the object's own
limits (no write over a sealed object, a code object or a slice, no execute over device memory) and beneath the rights the
caller's entry holds for the handle. So a connection's side has one writer because the domain library passes each
party its peer's side without write and the root refuses a write mapping of it, whatever the party's code does.

The memory every one of them shares is mapped by the service from its window, so a page has one window address whoever maps
it ([One page, one address](#erxos-on-fiasco)), and nothing copies. The data path makes no service request while the
other side is awake, as on erXos's kernel, and a ring is the ringer's own trigger, with no request either (FD16 for its
latency).

### vCPU upcalls on Fiasco

Catchable signals are delivered on this backend through Fiasco's vCPU upcall, with no change to Fiasco's kernel: the
backend carries `erx_vcpu_control`, `erx_vcpu_resume` and a bind of an IRQ object to a thread over Fiasco's own vCPU
interface, and [design-programs.md](design-programs.md#signals-in-liberx) runs on it as written, with the event rule
below. The facts it rests on were read in source, at the cited lines of `fiasco/kernel/src/kern` (`Modules.arm` one
directory up), and have not been executed; `native_signal` ([Verification](#verification)) runs them.

* **The interface is there.** The vCPU modules build into the fork's kernel for this architecture (`Modules.arm:94`,
  `:154`, `:166`), and a state area that is not the extended one needs no virtualization option. Fiasco's state area
  holds the saved frame, the event-enable and fault-diverting state bits, the saved state, a sticky pending flag set whenever
  a delivery queues at the thread and cleared when none is left (`vcpu.cpp:7-47`; `receiver.cpp:532`, `:696-703`), and
  the entry address. `vcpu_control` arms a thread through any capability to it, and arming cannot be undone
  (`thread_object.cpp:555-615`, `:603-609`); `vcpu_resume` acts only on the calling thread (`thread_object.cpp:255`).
* **Arming** runs `vcpu_control` on the thread with a Fiasco state area in a second kernel-user memory area of the task,
  which the backend adds with `l4_task_add_ku_mem` (`task.cpp:860-890`), since the task's UTCB area holds exactly its 128
  UTCB slots and Fiasco requires the state area to lie in kernel-user memory (`space.cpp:152-170`). The add charges the
  task's factory and can be refused; it goes through the root's one kernel-user memory add, so a refusal answers the arming
  call `ERX_ENOMEM` and leaves no area and no armed thread ([The construction](#the-construction)). Every state bit that
  diverts faults or selects vCPU user mode is clear, so page faults still reach the pager and exceptions the exception
  handler, the task's gate and from there the fault gate (`thread-vcpu.cpp:79-100`, `thread-ipc.cpp:1017-1052`). The
  ABI's `erx_vcpu` area stays the public one in the thread's record.
* **A bind to a thread** runs `l4_rcv_ep_bind_thread(irq, thread, label)` on that thread, outside the dispatcher. A
  task's stop detaches it at its first step ([Task exit](#task-exit)).
* **An upcall.** A delivery to an armed thread that is in no IPC and has events enabled enters the upcall
  (`receiver.cpp:597-599`, `:661-691`): Fiasco saves the state bits, disables events and fault diversion
  (`context-vcpu.cpp:166-174`), saves the general registers, stack pointer, program counter and processor state in the
  area, and jumps to the entry on the interrupted stack (`context-vcpu.cpp:176-179`, `arm/64/thread-arm-64.cpp:50-58`).
  A delivery from another CPU reaches the target's home CPU as a cross-CPU request (`irq.cpp:1003-1007`, `:942-972`).
  The backend entry copies Fiasco's saved state into the public `erx_vcpu` area in the ABI's layout, field by field
  (`abi/arch/aarch64.txt:37-41`), sets `saved_state` and the label, and enters the program's `entry`; nothing of
  Fiasco's layout reaches it. Fiasco saves no FP or SIMD register, so the backend entry, like `liberx`'s entry, executes
  no FP or SIMD instruction, and the trampoline's save is the one that keeps the interrupted code's FP state.
* **`erx_vcpu_resume`** validates the public frame, writes it into Fiasco's area and resumes through Fiasco's resume,
  which restores the whole frame (`task.cpp:93-116`) and, when the restored state has events enabled and the sticky flag
  is set, takes the queued delivery and enters the upcall again in the same call (`thread_object.cpp:312-346`), so K29
  holds at a handler's return.

**What Fiasco does not do, and the event rule.** Fiasco ends no semaphore down for a delivery: the down blocks in an IPC
state, so the delivery queues (`semaphore.cpp:175-179`, `receiver.cpp:663-664`). A umtx wait of `liberx` ends anyway,
because the raiser wakes the thread's wake word before it triggers the IRQ object, so this backend's umtx wait never
returns `ERX_EINTR`. Fiasco also takes no queued delivery when a kernel call returns to user mode: it checks only at a
resume and after page-fault and exception IPC (`thread-ipc.cpp:280`, `:331-334`, `:962`, `:999`, `:1075-1076`), and it
warns of kernel calls made with events enabled (`syscalls.cpp:18-22`). So a program's thread has events enabled only
while it runs its own code: `liberx`'s entry macro disables them at a call's entry, the backend's one path for a kernel
call made at depth zero disables them around it, and each return to the program's own code enables them, tests the
sticky flag, and if it is set takes the delivery with one `erx_vcpu_resume` of its own continuation. That costs two
stores and a load per call, and a kernel call only when a delivery is pending
([design-programs.md](design-programs.md#signals-in-liberx)). A chokepoint check keeps the backend's kernel calls in a
program behind those two paths.

### Faults, and the fault of the root task

A fault is one more message to the service, which never answers it while its task lives, because every committed page is already mapped; its reply slot waits for the task's stop ([Reply slots](#the-root-service)). It names the task,
by the gate, and not the thread, so a record's thread field is `unknown`, and it carries the address and instruction pointer.
A page fault is recorded as kind `memory`, with the low three bits of Fiasco's fault word in `cause`, where bit 1 says the access was a
write. Every exception is recorded as kind `undefined`, with the architecture's syndrome in `cause`: the record is for a reader, and
Phase 1 acts on no finer kind.

* **A domain's or a program's fault:** the fault record goes to the space's [fault gate](#fault-gates), and the faulting thread
  stays blocked in its fault message, which nothing answers, until its space stops; the space's other threads run on, as on
  erXos's kernel. The gate's server stops the space, which posts the exit record. `erx_thread_start` of the faulted thread,
  which on erXos's kernel resumes it after a repair, is `ERX_EINVAL` on Fiasco, since the service cannot tell which
  thread faulted and only created threads start; nothing here repairs a fault.
* **A test task's fault**, in a space with no fault gate: the record goes out through `l4_vcon_write`, then [task exit](#task-exit), with a status of -1. The machine continues.
* **The root's fault:** [the end path](#the-end-path).
* **The service's own fault** goes to `sigma0`, which repairs nothing: a recorded gap.

## The watchdog, the crash record and the console

### The watchdog

A root thread at priority 255 runs `watchdog.c`'s step machine: sleep one second, step over the pet word, which holds the time of the last pet. It ticks once a second whatever the period `P` of [the command line](#the-command-line), as erXos's kernel's timer does, so a board's hardware watchdog can be reloaded at each tick.
In deterministic mode the step is off and the machine page says so. A missed pet takes the end path and resets the machine, as a root fault does ([The end path](#the-end-path)).

**The hardware watchdog.** On a board whose platform record names a hardware watchdog, the Raspberry Pi 4's BCM2711
power-management watchdog, the same thread stands behind a hang of Fiasco or of the root on every boot. It arms the
hardware watchdog with the 4 s timeout of [design-platforms.md](design-platforms.md#trial-requests) before its first
tick and reloads it at every tick, through a window of the watchdog's block that the platform record names and only the
root maps, as it reaches the mailbox for the trial request. A hang of Fiasco or of the root stops the ticks, and the
hardware resets the board within the timeout: after a trial boot the firmware's one-shot flag is spent, so the committed
slot boots, and after any other boot the board boots its slot again. In deterministic mode, where the step is off, the
thread does not arm it. At an end the thread reloads no more and nothing stops the hardware ([The end path](#the-end-path)), so a board halted on request, and an end that
hangs, reset when it fires. An attended development board runs the hardware watchdog too, since the root arms it whatever its `config.txt` sets. A board stopped in the
kernel debugger, which development builds keep, resets within the timeout. A release kernel panics
instead, at a kernel trap as at any other fatal error ([The kernel](#boot-handoff)), and resets through PSCI's
system reset, which TF-A's BL31 makes by setting the same watchdog to 10 ticks, about 153 us, and its reset
configuration to a full reset (`plat/rpi/common/rpi3_pm.c`, `rpi3_watchdog_reset`): the board resets
at once, unless this thread's reload on another CPU lands inside those 153 us, and then the board stays up
for good, about one panic in 6,500. This is a platform item the root stands in
for, as the trial request is, not a kernel mechanism rebuilt in user mode. It arms the same watchdog as erXos's kernel,
on every boot only on Fiasco: on erXos's kernel the firmware starts it on an unattended board or the kernel under a
machine lease. Neither kernel ever stops it
([design-platforms.md](design-platforms.md#the-watchdog), PL4). A hang before the root's thread starts, in the
firmware's own stage or in Fiasco's boot, is not covered: U3 of [design-storage.md](design-storage.md#invariants) states
that on a board whose firmware does not run the watchdog from power-on a trial whose firmware stage hangs needs a power
cycle, and on Fiasco that stretch runs until the root's watchdog thread starts. The watchdog's registers and their sequence come from
a clean-room facts record of the power-management watchdog, as the RNG200's do.

Its numbers and mode come from [the command line](#the-command-line), with the design's defaults of 1, 5 and 60 seconds. **The pet is the design's
own**: `erx_watchdog`, a process at priority `max` of the release's `kernel`, started among `kernel`'s first children, right after `on_load` lets a module with a NIF load, calling the watchdog NIF from a
normal scheduler every half second, shorter than any `P` or `D` the command line can set, since those count in seconds. It pets unconditionally and reads no `liveness` record, so a pet says only
that schedulers run and timers fire, and a release with no services is no special case: the first pet follows the first period. A call that
never yields holds the pet for as long as it holds its normal scheduler, so ERTS prepares a module for loading, the longest such call seen at
boot, on a dirty CPU scheduler (edit 76 of [design-runtime.md](design-runtime.md#the-edits-outside-syserxos)). Until the first pet the boot races `B` alone, from the watchdog thread's start, which covers ERTS's start,
`init` and `kernel`'s start up to that process. A hang in any of them ends the machine with a crash record at `B`, as it should.

The root itself never pets on ERTS's behalf: a pet must mean that schedulers run and timers fire. The harness gives QEMU `-append` from one table: TCG
`erx.watchdog=1,30,600`, HVF the defaults, deterministic runs `erx.det=1`. A run's own deadline is at least `B + P + 60` seconds, so a stuck boot ends in the
crash record rather than in the harness's kill: the deadline counts from QEMU's launch and `B` from the later start of the watchdog thread, a missed
`B` is seen at the next tick (`watchdog.c:159-163`), and the record takes time to print. The 60 is a test margin, not a promise about the boot. The time to the first pet is about the time to `erx_console`'s banner, which `production_image`'s report holds under both accelerators. A first pet past 60 seconds under HVF is a finding to explain, not a number to raise.

### The end path

Every end of the machine is `erx_fiasco_end` with a named cause (`liberx/backend/fiasco/end.c`), and the machine's end itself is
private to that file, so nothing ends the machine without one; the build check `fiasco-machine-end` keeps
`l4_platform_ctl_system_shutdown` to that file. A root fault, the root's own stop and `erx_machine_end` reach it on
the service, a missed pet on the watchdog, and a refusal, of the boot or of a kernel or service step the root cannot go on without,
on whichever root thread met it. A task holds no platform control, so a task's reaper that is refused sleeps instead. A test
root's own power-off, when its test passes or fails, is a requested one, made on its own thread. It is best effort and takes no lock.
The service answers `erx_machine_end` for the root task alone and refuses it from any other task with `ERX_ENOTSUP`, as it refuses
`erx_log_take`, since on erXos's kernel only the root resource carries the `POWER` the call needs
([design-kernel.md](design-kernel.md#kernel-calls), K31).

1. **One caller.** An atomic exchange of the `ending` word in `end_take`, which every end path calls, the watchdog's
   included; the loser sleeps forever. The winner closes the kernel's route in the same function, which writes the
   kernel's ring out to the UART, before any write of its own ([The kernel's lines](#the-kernels-lines)).
2. **The log.** On the thread that owns the log ring, the service in a root, or the debug-log probe's one thread, which has no service,
   which alone writes it, lines the log service has not taken go out through `l4_vcon_write`; lines it has taken and the console has not yet
   written are not among them ([design-log.md](design-log.md#the-emergency-path)). On any other thread, the watchdog's or a root
   thread's, whatever the cause, the service may be mid-write, so the ring is skipped. The thread decides, not the cause
   (`erx_fiasco_log_owned`), since the thread is what makes the drain safe.
3. **The record.** After a fault or missed pet, the crash frame that [design-kernel.md](design-kernel.md) defines and
   `tools/lib/erx/crash_frame.rb` reads, through `l4_vcon_write`. No thread is stopped first.
4. **The end.** A last line through `l4_vcon_write` naming the end taken, `erx: end off`, `reset`, `panic` or `trial`, as erXos's
   kernel's last line names its end ([design-kernel.md](design-kernel.md#console-log-and-panic)), so a test reads which end was taken.
   Then, by `how`:
   * `ERX_END_OFF`: `l4_platform_ctl_system_shutdown(L4_BASE_ICU_CAP, 0)`. `ERX_END_RESET`, a root fault, the root's own stop and
     a missed pet: the same with 1 (`platform_control_object.cpp:82-96`).
   * `ERX_END_PANIC`: the crash record of cause `ERX_CRASH_HALT` at step 3 and a line saying the system domain asked, then the
     reset.
   * `ERX_END_TRIAL`: Fiasco's platform control knows only off and reboot, so the platform's trial request is the root's, in user
     mode, as one of the platform items the system domain stands in for. The service refuses the call with `ERX_ENOTSUP` before
     step 1, stopping nothing, while the boot value is `unknown`, as erXos's kernel does, which it is on every platform without a
     trial request. Otherwise it makes the request of [design-platforms.md](design-platforms.md#trial-requests) and resets: on
     QEMU `virt` the last line, `erx: end trial`, is the request, which the harness reads as it plays the firmware; on the
     Raspberry Pi 4 the root sends the firmware's reboot-flags property with the `tryboot` flag and then its reboot notification
     through the mailbox, each polled at most 1 s, from the mailbox's window, which the board's platform record names and only
     the root maps. A mailbox error or timeout resets without the flag, so the committed slot boots, as a dropped request does on
     erXos's kernel. The root does not arm the hardware watchdog before the request, as that design does; it arms it at the
     start of every boot, the trial boot included ([The watchdog](#the-watchdog)). A trial boot whose domains hang misses its pet, and the root's
     watchdog thread resets the machine as for any missed pet; a hang of Fiasco or of the root stops the thread, and the
     hardware watchdog resets the board. Either way the firmware's one-shot flag is then spent and the committed slot boots.
     Only a hang before the root's watchdog thread starts, in the firmware's own stage or in Fiasco's boot, stays hung until
     the harness's deadline or a power cycle, after which the committed slot boots.

   Under `-no-reboot` every end exits QEMU. If the shutdown call returns, the thread sleeps until the harness's deadline.

Which end each cause takes is a pure function over the closed set of causes, `erx_fiasco_end_how`
(`liberx/backend/fiasco/end_how.c`), and the host tests hold it to this: only a requested
power-off ends with `ERX_END_OFF`; `erx_machine_end` with `ERX_END_RESET` and every end nobody ordered, the root's own stop
(ERTS's `halt` on a boot that fails), a root fault, a missed pet and a refusal, end with `ERX_END_RESET`, so that an update's
trial boot that fails, faults or hangs falls back to its other slot ([design-system.md](design-system.md#boot)). This is `erx.panic=reset` on every build: Fiasco has no `halt`, so a
failure, fault or hang that repeats on every boot repeats the reset.

### Device records

The root hands the system domain's ERTS a record of each device the manifest places, as it hands it
the console's words, and the records are the device service's catalogue, which on erXos's kernel
comes from the root resource's device list: for each device of a unit the manifest gives to
no other domain, so the system domain holds it, at a device-tree path, whose role and compatible string are a row of the kinds table in
`include/erx/device_kinds.h`, it gives itself the device as a holder's creation gives one: at boot,
before ERTS starts, it makes, for the whole unit, one register window with `erx_mem_create_physical`
over each run of pages the unit's registers cover and one IRQ object with `erx_irq_create` for each
distinct line its devices name, so the records of devices that share a page or a line name one handle
([design-shared-devices.md](design-shared-devices.md#the-unit-rule)), and, for a device with DMA memory, the
device's one contiguous object of that size with `erx_mem_create_contiguous_in` inside its DMA range, each in its own
table, and adds the same `-erx_record given ROLE PERIPHERAL PATH WINDOW_H OFFSET SIZE LINE_H MARK MEM_H
MEM_SIZE CLOCK COHERENT MAC INDEX` record a holder's page carries, below (`liberx/backend/fiasco/runtime_entry.c`, `device_give`;
`erx_boot_device_window` computes the pages and OFFSET). ROLE and PERIPHERAL are the row's names,
PERIPHERAL the peripheral's name in the CMSIS-SVD source that `erx_device` opens it as, PATH
the device-tree path of the row, which names the device to its driver; the
pages, SIZE, the line and MEM_SIZE come from the manifest's device entry: its register window,
its interrupt line and the DMA memory the platform reserves for it. So a device that does DMA
has one form in every domain: its queues are carved from its one memory, and the system domain's
driver opens it exactly as a holder's does. Nothing deletes these objects, since the system
domain holds the device for the boot and its fault resets the machine; an object the backend
refuses refuses the boot, naming the record. The host link's UART and a line's UART
([design-bluetooth.md](design-bluetooth.md#the-controllers-line)), which do no DMA, are the
physical records, `-erx_record device ROLE PERIPHERAL PATH BASE SIZE LINE MARK CLOCK INDEX OFF ON`, PATH as in the given record, INDEX the
device's row in the manifest's device table, which a line grant's `device` names, and OFF and ON its power line's off and on
times in milliseconds from that row, 0 and 0 for a device with none ([design-bluetooth.md](design-bluetooth.md#the-power-line)); the root writes the
line's record for that row alone, a physical record for a `uart` row and the given record of its
kind row for a `serial` row, a virtio console, which does DMA. The record holds those words and no others: BASE and SIZE are
the device's own registers, and nothing in it names the pages its unit's other devices cover. CLOCK is the device entry's
clock in hertz, which the driver reads and the NIF does not. The record's window and line the device
NIF makes from the numbers in the system domain, as it does for the console's UART from `-erx_record
console`; a physical device has no queue. The rows are QEMU `virt`'s virtio-mmio
transports, each with compatible `virtio,mmio` and the peripheral of its kind, which copies the
transport's registers and adds the kind's configuration fields (`hw/svd/virtio_mmio/virtio_mmio.svd`):

| Manifest role | Record role | Peripheral | Holder |
| --- | --- | --- | --- |
| `block` | `block` | `virtio_blk` | the storage domain, or the system domain when no storage domain is configured |
| `network` | `net` | `virtio_net` | the network domain, or the system domain when no network domain is configured |
| `gpu` | `gpu` | `virtio_mmio`, the transport alone, since its driver reads no configuration field | the display domain |
| `input` | `input` | `virtio_input` | the display domain |
| `serial` | `line` | `virtio_mmio`, the transport alone, since its driver reads no configuration field | the system domain, whose line service drives it for the line grant that names it ([design-bluetooth.md](design-bluetooth.md#the-line-on-qemu-virt)) |

A `framebuffer` row, the firmware's framebuffer on the Raspberry Pi 4, is no row of the kinds
table: its holder's record is the root's framebuffer record
([design-device-tree.md](design-device-tree.md#facts-into-records)), not a `given` record,
`-erx_record framebuffer WINDOW_H OFFSET SIZE WIDTH HEIGHT STRIDE FORMAT`: the handle of a physical
memory object over the framebuffer's pages and nothing else of its row's window, mapped as
device memory, the framebuffer's offset in the first page and its bytes, and its geometry and
format's name from the `simple-framebuffer` node. The system domain holds it as any other
domain does, the root making the object in its own table, and a framebuffer the root did not
place has no record, its holder finding none, and only the root's line. The development
manifest of the Pi places the unit with the display domain, whose driver `erx_firmware_fb`
reads the record with `erx_device_record:framebuffers/0` and maps the object with
`erx_device:framebuffer/0` ([design-runtime.md](design-runtime.md#the-device-nif)); the board's
console shows the root's line for it.

The development manifest of QEMU `virt` places the block and network devices, in the storage and
network domains, and the gpu, in the display domain, which holds the platform record's `display`
unit. It places no input device, since the record's `display` unit lists the gpu alone, and no
`serial` device, which only the Bluetooth suite's manifest places. A boot of the
development image that attaches no gpu leaves the gpu's transport empty, and the display domain
runs without a screen.

The network domain runs the network stack, `erx_net`, and its virtio-net driver over the `net`
record ([design-network-stack.md](design-network-stack.md)); the system domain holds no `net`
facet ([design-system.md](design-system.md#the-manifest), property 15). In Phase 1 the network
domain is trusted: its virtio-net device is unconfined, so it can reach all memory through it, and
the domain is in the trusted base (FD12).

`gpu` and `input` are values of the manifest's `mf_device_role` beside `network` and `block`, since
the manifest check reasons about a display domain's devices by role
([design-system.md](design-system.md#the-manifest), property 9), and so is `serial`, since it
refuses a placed `serial` device that no line grant names (property 8). A further kind of device is one more row.

**A device the system domain holds**, the console's UART, the host link's, a block device
with no storage domain and a network device with no network domain, its driver opens
from its record as below, the UARTs by their addresses and the rest from the objects the root
gave itself. The host link's UART has a
record only under `erx.hostlink=1` ([The command line](#the-command-line)). **A device another domain
holds** reaches it as on erXos's kernel: the creation of the configured row that holds it gives it,
and the give's body on this backend creates the register window with `erx_mem_create_physical` over the
record's base and size, the line's IRQ object with `erx_irq_create`, and the device's contiguous
memory at its first give, all in the root, and passes them to the holder. The give's resource step makes
nothing, since neither backend has a resource object and every device create ignores its resource argument
(`liberx/backend/api.h`); the window and line come from the catalogue entry at the give's index, which is the
manifest's device row, so one index names the entry and the device. The holder's driver
reads their values from its boot page's `given` record, maps the window, binds the line to its own group
and acks it ([design-runtime.md](design-runtime.md#the-device-nif), [design-system.md](design-system.md#devices)).
A `pci` device on a configured row is given the same way, in the root, as the domain library plans its
give ([design-pcie.md](design-pcie.md#the-catalogue-and-gives)): a register window with
`erx_mem_create_physical` for each placed memory BAR over its span, its IRQ object, `ERX_IRQ_MSI` over a
line of the MSI frame or `ERX_IRQ_LINE` for a closed bus's line, and its contiguous memory with
`erx_mem_create_contiguous_in` inside its DMA facts. Its given record names the function's place, each
BAR's window with the BAR's hardware size, and, for an MSI-X route, the doorbell, the data and the table's
BAR, offset and size, from which the holder's NIF writes the table
([design-runtime.md](design-runtime.md#the-device-nif)).
No device call is made from a task other than the root, except a map, a bind, an ack and
`erx_mem_dma_addr` on objects the holder was given. Every such device is unconfined: its holder
reaches any physical address through its DMA, which the manifest check allows in a development
build alone.

**A holder's end and its restart.** A device's objects are the root's, so the holder's end deletes none of them: its
mappings go with its task, and its line's bind goes with its group ([Task exit](#task-exit)). At the holder's exit record
the domain library deletes the register window's object and the line's IRQ object, each by its own handle, and keeps the contiguous memory, the
device's for the boot, as [design-system.md](design-system.md#devices) says; the row's next creation gives the device with
a window and a line's object made again and installs the same contiguous memory instead of making new. A register range stays in the root's device
window for the boot once `sigma0` gave it, so a create over it maps from the window again and asks `sigma0` for nothing;
two devices whose ranges overlap are refused above this backend, by `erx_dom_plan_unit_give`. The new driver's
`negotiate/2` resets the device before it posts anything and before it installs a ring, and nothing reads the kept memory
before then, so what the old holder left in the device or its memory is not trusted
([design-runtime.md](design-runtime.md#the-device-nif), "The reset rule").

Which of QEMU's 32 virtio-mmio transports is which device is configuration: the platform
record names a transport for each role, the bus the harness pins that role's device to,
and the manifest's unit says who holds it. A 4 KiB page holds eight transports, and a
give windows whole pages, so each of the record's four virtio units is one page with every
transport on it ([The unit rule](design-shared-devices.md#the-unit-rule)): the driven
transports by their role and the others as devices of no kind, `ordinary`, which no
driver opens, so what a holder's window reaches is what its unit lists. The disks take the
top page, `/virtio_mmio@a003e00` for the first and each next disk the transport below it,
and the network device the page below, `/virtio_mmio@a002e00`; the display unit the page
below that, whose graphics device is `/virtio_mmio@a001e00`, the keyboard
`/virtio_mmio@a001c00` and the tablet `/virtio_mmio@a001a00`, the record's transports, to
which the harness pins them (`QemuPlan.placements`). The gpu has 9 MiB of DMA memory: the screen
image of the largest mode the display design sizes, 1920 by 1080 in `x8r8g8b8`, 8,294,400
bytes, and 1,142,784 bytes for the control queue's ring and buffers; each input device has
64 KiB, room for its event queue's ring and 64 buffers of one event. The line unit takes the
page below that, the Bluetooth controller's line: a virtio console of role `serial` on
`/virtio_mmio@a000e00`, unconfined, with 256 KiB of DMA memory, room for its receive and
transmit queues' rings and 16 buffers of 4 KiB in each
([design-bluetooth.md](design-bluetooth.md#the-line-on-qemu-virt)). The development
manifest leaves it unplaced and only the Bluetooth suite's manifest places it, since the
harness backs that transport only there. The `device_give` QEMU suite places the display
unit, which the site manifest leaves free with the display domain, on a configured row,
whose domain reads the graphics transport's magic, is halted, and reads it again from what
the row's restart gave it. The website's machine, v64,
which boots the website's image, has no setting for a device's transport, so `site/terminal.js`
fills the rest of the disks' page with blank read-only disks and the network device falls
on its transport ([site/README.md](../site/README.md#the-network)). The production image suite checks each
path, base and line against QEMU's own device tree, as it checks every recorded path. The
root reads no register to choose, since only `erx_device` touches a device's registers; the
driver's first reads of the transport, its magic, version and device id, say whether its
device is behind it. A manifest with no such unit has no record, and a machine without the
device boots the same, with nothing for its driver to drive.

A given record, a holder domain's or the root's own, has a word of its own, `-erx_record given ROLE
PERIPHERAL PATH WINDOW_H OFFSET SIZE LINE_H MARK MEM_H MEM_SIZE CLOCK COHERENT MAC INDEX`. ROLE and
PERIPHERAL come from `include/erx/device_kinds.h`. PATH is the device-tree path of the device's
manifest row, the name its driver gives it, a node path of at most `device_path_max` bytes
(`abi/erx_abi.txt`), which the manifest grammar holds `devices[].path` to; the record writers, the
root's reader and the domain library's view refuse any other path (`erx_boot_device_path_valid`),
and `erx_device_record` any other PATH word, so a name a driver shows holds no control or escape,
and reaches a display only through that sink's escaping function. WINDOW_H, LINE_H and MEM_H are
the values, in the holder's own handle table, of the window, line and memory objects the domain
library installed when it created the domain, or the root made for itself; OFFSET and SIZE place
the registers in the window; in a holder's record LINE_H is 0, the null handle, for a device whose
node raises no line, as QEMU virt's ECAM bridge's does not, which only the PCIe domain holds, and
`erx_device_record` reads it as no line, refusing it marked `shared`; MEM_H and
MEM_SIZE are 0 for a device that does no DMA; CLOCK is the
device's clock in hertz from its manifest row, 0 for a device whose driver reads none, so a given
PL011 has its clock as the host link's does; COHERENT is 1 when the device tree the firmware handed
over marks the device coherent, else 0; MAC is the hardware address that tree gives a network
device, as a 48-bit number, 0 for none
([design-device-tree.md](design-device-tree.md#facts-into-records)); and INDEX is the device's row
in the manifest's device table, as a physical record's, by which the PCIe domain finds a host
bridge's record for the `erx_pcie_bridge` whose `index` is that row
([design-pcie.md](design-pcie.md#the-bridge-seam)). Since each form has its own
word, the reader never tells one from the other by counting numbers, and a plain word of the
command line after a record cannot make one form look like the other.

MARK, in both forms and in `-erx_record console`, says whether the line is shared: `shared` when
another device of the unit names the line, `direct` otherwise
([design-shared-devices.md](design-shared-devices.md#lines-inside-a-domain)). The writer
decides it from the manifest, so no driver says whether its line is shared. The root marks
its own records shared when another device-tree device of the manifest names the line
(`liberx/backend/core/boot_manifest.c`, the boot view's relation, since the boot view puts
devices that share a line in one unit), and the domain library marks a holder's record
shared when another device of its unit names the line: the holder's creation makes one IRQ
object for such a line, in the first give whose device names it, and installs it once, so
every record of the line names it under one handle (`erx_dom_plan_unit_give`).
On the Raspberry Pi 4 the console's and the host link's lines are shared; on QEMU `virt`
every line is direct. A reader refuses a record whose MARK is any other word.

A driver finds its records with `erx_device_record:find(Role, Peripheral)`, which returns
each as a spec for `erx_device:open/1`: a `device` record's as the physical window and line
and `clock => Hertz`,
a `given` record's as `{object, Window, Offset, Size}`, `[{object, Line}]` and, for a nonzero
size, `memory => {object, Memory, Bytes}`, `clock => Hertz` and, for a COHERENT of 1, `coherent => true`; and `{ok, []}` when there is none. Words after a
record's numbers are not the record's. Each number must be decimal within its field (64, 64,
32 and 32 bits for a `device` record, 64 bits each for a `given` one but its clock's 32), or the records of that
role and peripheral are refused with a stated reason
(`erx_device_record:find/3`, which has a fuzz target). The hosted entry adds no record,
since a hosted runtime has no devices. More records than `ERX_BOOT_DEVICES_MAX` refuse
the manifest at boot.

### The firmware request

`erx_firmware_request(resource, index)` names a row by its device's resource, and the backend has no
resource objects ([Device records](#device-records)). So, as with a device's memory ([The pool](#the-pool)),
the backend takes the row as a value: `erx_firmware_request_row(row, answer, length)` of
`liberx/backend/api.h`, the root's alone, which erXos's kernel does not have. A row is a tag of the closed set
`fw_tag` of `abi/formats/vc_property.txt` and its argument, both the manifest's, which the generator
checked against the tag's declaration; the core's declaration of the tag (its request, its window and its
least answer) comes from the tag, never from the caller, and no member of `fw_tag` reads the board's key.
The call itself checks nothing of the argument, so that the caller chooses neither holds against other
domains only (FD29). The domain library's firmware entries are an allow-list, each resolving the one row its
request names against the manifest's firmware request records, which the view keeps as it is built
([design-abi.md](design-abi.md#devices-and-partition-windows)): `erx_dom_lib_bridge_firmware`, a host bridge
row's notification, its first row; and `erx_dom_lib_power`, a power line's phase of `fw_power_phase`, the row
at the phase's index, for a device whose manifest row carries the line's times alone
([design-bluetooth.md](design-bluetooth.md#the-power-line)). Any other request answers `ERX_ENOTSUP` before
anything reaches the mailbox, and the entry otherwise makes the call. Each runs outside the library's lock,
which the call would otherwise hold for up to its deadline, and reads nothing written after the view's build;
the caller of the bridge's entry then hands its status to the bridge's catalogue under the lock, where `ERX_ETIMEDOUT` marks the
bridge `firmware_lost` (`erx_dom_lib_pci_firmware`, `erx_dom_pci_firmware`). Since the request runs outside
the lock, the device service, which made it, takes no report while any request is in flight, since one report
hands every bridge an intake, and no give of that bridge's functions is made while its request is in flight, so no give meets a bridge whose notification timed out before the mark lands
([design-pcie.md](design-pcie.md#concurrency)). The chokepoint `dom-firmware-entry` holds
`erx_firmware_request_row` to those entries. A driver names a bridge row and
nothing else, and the device service refuses a row it did not give the caller
([design-pcie.md](design-pcie.md#facets)). On erXos's kernel that one call is
`erx_firmware_request(resource, index)` inside `liberx` and the kernel resolves the row; nothing above
`liberx` changes. QEMU `virt`'s manifest has no firmware request records, so every request there is
`ERX_ENOTSUP`, and a root that keeps no mailbox answers the call `ERX_ENOTSUP` too.

**It runs in the caller's thread.** The root service's one thread serves every task's requests and faults
([The root service](#the-root-service)), so a poll of up to 1 s there would stall every domain. The call
runs the mailbox core (`kernel/core/vc_mailbox.c`) in the thread that called it, the device service's firmware
worker on a dirty I/O scheduler, and sleeps between reads of the mailbox's status (`l4_ipc_sleep`). A short
lock on the core's state, the mailbox lock of [Locks](#locks), taken for each step and never held across a
sleep, keeps the request apart from the root's trial request, which the service makes at the end path and
which, meeting `ERX_EBUSY`, sleeps until the core is idle, at most the deadline of the request in flight,
before it posts, as erXos's kernel's trial request waits ([design-kernel.md](design-kernel.md#firmware-requests)); the core keeps the rest: the 1 s deadline from the call's start, `ERX_EBUSY` beside a
request outstanding, and after an `ERX_ETIMEDOUT` every later call answered `ERX_ETIMEDOUT` for the boot, so a
late answer only ever lands in the buffer page, which nothing writes again.

**The buffer is one page of the root's image**, page-aligned in its `.bss`. Bootstrap runs the root at its
link address and `sigma0` maps each of its pages there (`root.ld`, `service.c`), so the page's physical
address is its address. It is no pool page: the pool's total is the manifest's devices' `dma_memory`, and the
buffer is no device's memory. The mailbox carries 32 bits, so the core refuses a page at or above 4 GiB with
`ERX_EINVAL`; the root's image lies in the first GiB on every board whose platform record has rows.

**The page stays cached.** The request is written, cleaned to the point of coherence (`DC CVAC`, then
`DSB SY`) and posted; after the answer that names the buffer, the page is cleaned and invalidated
(`DSB SY`, so that the read of the answer ends before any line goes, `DC CIVAC`, then `DSB SY`) and read once
into a copy, which the core checks. Nothing writes the page while
the firmware owns it, so the invalidate discards nothing. These are the user-mode instructions the device
NIF already runs for a device that is not coherent ([design-device-dma.md](design-device-dma.md)).

**The posted word is the page's physical address with channel 8.** The firmware wiki exempts the property
channel's messages from the VideoCore's bus addresses: they carry the address the CPU sees with its MMU off
(`Accessing-mailboxes.md`, line 25, of the pinned copy of 2026-11-21, SHA-256
`bdbd0a5535e67103a82bc5f65c058180aa93672ff26f9e09b30c235d8af629ac`). Fiasco's bootstrap posts its buffer the
same way (`bootstrap/server/src/platform/rpi.cc`, lines 77-78), and so does the `raspi4b` suite's stand-in for
the firmware (`test/raspi4b/firmware_fb.c`). Should the board refuse the raw address, which probe B1 shows as
a timeout or an answer outside the interface ([design-usb.md](design-usb.md#the-vl805s-firmware)), the
fallback is the alias `/soc`'s `dma-ranges` gives the first GiB, the physical address plus `0xc0000000`.

### The booted slot

Phase 1 maps no machine page to the system domain, so the root hands its
ERTS the boot value and slot as it hands it the device records: from the
handoff, which bootstrap derived from `/chosen/bootloader`, it adds
`-erx_record boot VALUE SLOT`, by the names of `include/erx/core/boot_pair.h`
(`unknown none`, `normal a`, `trial b` and so on). The hosted entry adds
none, which reads as unknown.

The domain library adds the same words to a configured block holder's
arguments, so the block driver knows the booted slot without a machine
page. Once the partition table is admitted, `erx_blk_service` starts one
read-only window of role `system` on the booted slot's system partition,
whose sectors come from the medium layout of the ABI file alone, for the
storage domain that serves `system`, the holder the manifest's `system`
window row names; a boot with no slot, an unknown
boot, starts none, as the storage design requires, and so does a holder
whose `system_image` record, below, is absent or refused, so the window
follows the manifest's row, the record's one writer being the domain
library. That storage domain
serves the window as the `system` tree, with the read-only `erx_fs`
backend over `erx_erofs`, as on erXos's kernel
([design-storage.md](design-storage.md#the-system-tree)), and every other
domain reaches its files through a grant. The driver reads no manifest.
To that holder alone the domain library adds one record more, from the
manifest's `system_image` fields, `-erx_record system_image LEN
TREE_OFF TREE_LEN SALT ROOT [record_volume]`: the image's length and the tree's offset
and length in bytes, in decimal, and the tree's salt and root hash in
lowercase hex, with which `erx_storage_system` opens the image in
`erx_verity` (E1 of [design-storage.md](design-storage.md#invariants)).
The sixth word, the `record_volume` window role's name, is there exactly
when the manifest holds a `record_volume` window, which the manifest
check gives only the `system` window's holder
([design-ssh.md](design-ssh.md#roots-login-keys-on-the-medium)) and the
domain library's view refuses on any other row. It tells that holder's
block service to start the read-only `record_volume` window on the whole
record partition (`erx_blk_table:booted/1`), whatever slot the boot
names, since the record partition belongs to neither, and its storage
domain to start the `login_keys` mint on it; a record of five words
starts neither, and the manifest is the record's one source, as for the
`system` window.
The packer writes the tree in whole blocks right after the image, under
the salt a package's image takes, the image's own SHA-256
([design-packaging.md](design-packaging.md#building-and-packing)), which
one function, `Erx::AppPackage.image_tree`, picks for both.
The one reader of the record is `erx_device_record:system_image/1`, a
pure function over the record words `erx_device_record:records/0`
holds, with a fuzz target as `find/3` has: it takes exactly one
`system_image` record of five words, or of six whose sixth is exactly
`record_volume`, which `erx_device_record:record_volume/1` answers from
the same record, LEN, TREE_OFF and TREE_LEN
each a decimal of at most 20 digits within 64 bits, SALT 2 to 64
lowercase hex digits, an even count, for a salt of 1 to 32 bytes, as
the manifest's image salts are bounded, and ROOT exactly 64 lowercase
hex digits, and refuses any other shape, a second record and an absent
one with a stated reason. On a refusal `erx_storage_system` opens no
image and logs the reason, and every request on a grant of the `system`
tree answers `eio`, as on a boot that names no `system` window: the
image packages are absent and nothing reads an unchecked block. The
manifest check refuses a manifest with a `system` window row and no
`system_image` fields, or with an empty salt, so a built image never
takes that path, and refuses `system_image` fields with no `system`
window row, which would reach no holder. The reader's host test covers each word malformed in turn,
a missing, extra or other sixth word, and a second record or none, seeded with a reader that takes
ROOT of any length and one that takes any sixth word as the window's name.

### Drive records

The device service names a device's windows to its holder when it gives
the device ([design-storage.md](design-storage.md#data-model), "Partitions
are windows"), and the holder reads no manifest, which only the system
domain slices ([design-system.md](design-system.md), A10). A partition
window needs nothing beyond its role, since the medium layout of the ABI
file places it; a drive window names a drive number that no layout
holds ([design-drives.md](design-drives.md#manifest-rows)). The domain
library therefore adds to a configured domain's arguments, beside its
device records, one record for each drive window whose device lies in
one of the domain's gives: `-erx_record drive ROLE N`, ROLE the name of
that device row's `mf_device_role`, `usb` or `block`, the only two a
drive window may lie on, and N the row's `drive` field in decimal; a
device's records follow the window table's order. The window's holder,
the media domain, gets none: what it needs of a drive comes through the drive's
grant. The system domain gets none either, since the manifest check
refuses a drive on a device it holds, and the hosted entry writes none.
`ERX_BOOT_DRIVE_WORDS_MAX` in `include/erx/boot_words.h` bounds one
record's words, the flag, `drive`, the longer role word `block` and one
number word; how many a domain gets is the manifest check's bound, at
most `usb_drives_max` on a USB domain's controllers and exactly one for
a block drive's holder, which holds that device alone.

The one reader is `erx_device_record:drives/2`, a pure function over the
record words `erx_device_record:records/0` holds, with a fuzz target as
`find/3` has (it joins `tools/fuzz/erx_device_record.rb`).
`drives(Role, Arguments)`, Role `usb` or `block`, answers
`{ok, Numbers}`, the sorted drive numbers of that role's records, `[]`
for none, a normal state, or `{error, {bad_device_record, Reason}}`. It
reads every record of the word `drive` whichever role is asked, and
refuses them all with a stated reason when any has other than two words,
a role word other than `usb` or `block`, which it compares as a string
and never makes into an atom, or a number that is not a decimal of at
most ten digits below `mf_none`; when two name one number; when more
than `usb_drives_max` are `usb`; or when more than one is `block`. So a
domain gets its whole set of drives or none, never a part.

* **The USB domain** reads its `usb` drives when its places start and
  starts one drive grant, `erx_blk_drive`, for each; a ready medium takes
  the lowest free number among them, and each row's grant reaches the
  media domain as the facet the domain service mints for that row
  through the USB domain's drive mint, which refuses a number these
  records do not name
  ([design-drives.md](design-drives.md#how-the-grant-reaches-the-media-domain)).
  On a refusal its places log the reason and start no grant, so every
  ready medium shows `no drive`.
* **A block device's driver**, `erx_blk`, reads its `block` drive. With
  one, it serves its device's medium as that drive: one grant, started
  by the device process and occupied by it, the drive mint, one
  window of role `drive` over the whole medium under a medium
  reference, and no partition table read
  ([design-drives.md](design-drives.md#a-drive-and-its-medium)). With
  none it reads the medium's layout as it does for the boot medium. On
  a refusal it serves no window at all and logs the reason: it cannot
  tell whether its medium is a drive, and reading the layout of a
  medium meant to be served whole would parse a stranger's table in a
  domain that holds a device.

The writer's host test builds a manifest with two USB drives on one
controller and a block drive, and finds each holder's records and no
record in the media domain's or any other domain's arguments, seeded
with a writer that keys on the window's holder instead of the device's,
so the media domain gets the records. The reader's host test covers
each word malformed in turn, a third word, a number twice, five `usb`
records and two `block`, and a `block` record beside a domain's `usb`
ones, which each role's answer keeps apart, seeded with a reader that
takes any role word and one that keeps the first of two records naming
one number.

### The console

The console's record is `-erx_record console PERIPHERAL BASE SIZE LINE MARK CLOCK`, which the root writes from the device entry `machine.console` names (`erx_boot_console_words`). PERIPHERAL is the CMSIS-SVD peripheral of the entry's compatible string, from the one table of UART kinds, `erx_uart_kinds` in `include/erx/device_kinds.h`, beside the kinds a give drives and apart from them, so a console UART is never given: `arm,pl011` is `pl011`, which is also the host link's UART, and `brcm,bcm2835-aux-uart` is `mini_uart`. The record's first word, `console`, is the row's too. The manifest check refuses a console of any other compatible string, naming it, and the root writes no record for one. The console starts the driver of the peripheral its record names, `erx_pl011` for `pl011` and `erx_mini_uart` for `mini_uart` (`erx_console:console_driver/1`), and stops with a stated reason at any other word, at no record, or at more than one, so the console makes no atom of a record word. The hosted entry writes `-erx_record console stdio`, the same record with no UART after it, which names `erx_stdio`. The driver opens the record's window and line through `erx_device`. It takes exactly one such entry, each number in decimal within its field of the boot manifest's console (64, 64, 32 and 32 bits), MARK `direct` or `shared` as a device record's, and the clock not 0, and stops with a stated reason otherwise (`erx_pl011:console_uart/1`, which has a fuzz target). The clock, the UART's in hertz from the platform record, times a character while the driver reprograms the UART and gives the divisors for 115200 baud when the boot left the UART unprogrammed; a clock with no integer divisor of 1 to 65535 for that rate stops the driver before it touches the UART. A plain `erx.arg` word that joins any of these lists of arguments, the console's or a device record's, is ignored.

Without `-serial_input`, `Config::serial_input` stays `Serial_no_input` (`config.cpp:246,278-282`), so the kernel never attaches the UART's
receive line, which `Irq_chip_gen::attach` would refuse the driver (`irq_chip_generic.cpp:77-81`). A development kernel's panic enters JDB on the
console and the harness's deadline ends the run; a release kernel's reboots ([the kernel](#boot-handoff)).

**The sink** is a variable the service owns. `erx_debug_log` copies `len` bytes from the caller's public UTCB, escapes them, and writes to
`l4_vcon_write` on `L4_BASE_LOG_CAP`, the kernel's console, which polls the UART until the handoff, or to a ring of `log.c` records. `erx_log_read` runs `erx_log_copy` into
its window for a log reader of the root, and `erx_log_take` runs it for the log service. The window is the root's own memory, which the service shares and writes in place, so a task's read or take is `ERX_ENOTSUP`; the reply's three words are the next cursor, the records lost and the bytes written. The log keeps one position of what has been taken, which only the early console and the log service's take move. The early console takes each record as it writes it. The handoff is the console's first `erx_log_take`, after which the service writes no record to the UART and records wait in the ring. From then on the log service, `erx_syslog`, polls `erx_log_take`, which copies the records nobody has taken and takes them, and hands each line the log core rendered, escaped, to `erx_console`, which writes it to its driver ([design-log.md](design-log.md#the-kernels-records)); taking the log back at the machine's end hands the UART back to the early console, which writes the records past the position and then each new one. So a record reaches the UART exactly once and in order across both changes of taker, with no cursor for the log service to learn, and a ring that wraps while parked costs a line saying how many records were lost. Every other reader, such as `dmesg`, reads with `erx_log_read` from a cursor of its own, as on erXos's kernel ([design-kernel.md](design-kernel.md#console-log-and-panic)): a read changes nothing the console or another reader sees, a cursor older than the ring's oldest record is told how many records it lost, and a cursor past the end of the log, the number the next record will get, is `ERX_EINVAL`. A read from 0 also returns the records the early console already wrote; when hosted that is every record, since standard error shows each one as it is written. The two reads are two calls rather than modes of one, so the take's request has no cursor to misread and no cursor value means "take". The service is the serialization `log.h` requires. A session reads the log as the inspection path `[kernel, log]` through its inspect facet, so only a session whose facet has scope `all`, `root`'s in a development build, reads it, and the read itself runs in the system domain, which alone holds the log on this kernel ([design-live.md](design-live.md#the-inspect-service)).

**A domain's runtime**, the system domain's root included, writes its standard output and standard error as records: `output_line.c`,
which the root's `libc_root_write.c` and a task's `domain_entry.c` share, gathers each thread's bytes
into lines with `erx_line_gather_write`, in a gather in the thread's own record, so every thread that has a record can log, and logs each line, without its newline, through `erx_debug_log`, so the log escapes it and
labels it with the task's space, and once the console driver holds the UART, `erx_console` writes it whole between the driver's
other writes ([design-runtime.md](design-runtime.md#the-console-and-standard-io)). ERTS writes standard error a format fragment or a
byte at a time, so passed on as written, each byte would be a call of its own, falling between the driver's. A line longer than
`utcb_bytes_max` goes out in pieces of that size, one record each. A boot information page the entry refuses, before musl
starts, has its reason logged the same way, since the first thread has its record by then. The root service's thread has no record and writes no record of its own. Standard output
and standard error share a thread's line, and a line still unfinished when its thread or the task ends is dropped. Until the log service's first take the
early console writes each record as it is logged; from then on that output needs the log service, which is its cost: a record still
in the ring is lost at a watchdog end or an end on a thread other than the service, and one the log service has taken is lost
when the machine ends before the console writes it ([the end path](#the-end-path)); records are lost when the
64 KiB ring wraps before a take, and reach only `/proc/kernel/log`, not the console, once the log service's supervisor has given up
past its restart intensity ([design-log.md](design-log.md#the-kernels-records)); past 16 KiB a second of a space's lines the log drops and counts them.
The root's boot lines, before the handoff, and its refusals go to the UART directly, a refusal through the end path, which
closes the kernel's route first ([The kernel's lines](#the-kernels-lines)); on the service thread
`erx_fiasco_end_refused` writes a refusal after the end has taken the log back, so it follows the records the ring held.

**A program's standard output and standard error** deliver its bytes unchanged to whatever its descriptors name, a session's
tty or a pipe, as [design-programs.md](design-programs.md) gives every program; no program writes the machine's console. The
global console has one writer of unchanged bytes, the console driver, and every other text reaches it escaped and attributed,
through `erx_debug_log`'s records. The one exception is the test tasks of the test-task launcher in the root (`libc-test`'s
programs, which run with no descriptor table): `libc_task.c` hands their output to `erx_fiasco_task_write`, one `task_write`
request per `utcb_bytes_max`, and the service copies each piece from the caller's public UTCB to `erx_fiasco_console_write`, with
no record, no escape and no rate limit, so that the suite finds a test program's bytes as it wrote them. The launcher and the `task_write` body exist only in a development build's root
([What a test reads of a task](#reporting-kernel-objects)), so a release root's decoder answers `task_write` with
`ERX_ENOTSUP`. In a development build the service answers
`task_write` only for a task whose record the launcher marked as a test task when it created it. The launcher creates
through `test_space_create` of `fiasco_call`, `space_create`'s request under its own number, which sets the mark and
which the service refuses with `ERX_ENOTSUP` from any task but the root, as it refuses the root's other calls, and the launcher alone sends it. No other
creation sets the mark, so `erx_space_create` from any task, a domain's and a session's included, makes a task whose `task_write` answers
`ERX_ENOTSUP` and writes nothing. The pieces of a long write are separate calls, so another thread's output can fall between
them, and a test task's output goes to `l4_vcon_write` whatever the sink is, as the ring's records have no form for unchanged
bytes. A test root never takes the log, so there the kernel's route stays at the UART and the bytes reach it unchanged; after
a take they would reach the kernel's ring and arrive escaped, as kernel records ([The kernel's lines](#the-kernels-lines)).
`erx_debug_log` is the way out for everything else: a labelled, escaped record.

Fiasco's own console (`glue_libc.cc`) puts a carriage return ahead of every newline, whoever writes it, as a terminal's output
mapping does. That is the one difference between what a program writes and what the serial log holds.

**The handoff.** The service runs the log service's first `erx_log_take` after its last `l4_vcon_write` of a log record: it sets the sink
to the ring, moves the kernel's own route to the kernel's ring ([The kernel's lines](#the-kernels-lines)), and replies. `erx_syslog` makes that take as it starts, and `kernel_sup` starts its supervisor, `erx_syslog_sup`, before `user_sup` starts `erx_console` and its driver, so the driver's first touch of a register follows the
service's last write of a record and the kernel's last write of a line, whatever else maps the UART's page: the handoff names the console, not an address, and a sibling device's
record in the console's page hands nothing over ([design-shared-devices.md](design-shared-devices.md#the-console)). A program's output goes on as above. A
partial boot starts no console, so its log lines and the kernel's reach the UART for the whole run.

#### The kernel's lines

Fiasco prints after user mode is up. The release kernel leaves out only the debugger and the kernel's console input
(`tools/lib/erx/fiasco_config.rb:42`), and `config/fiasco/kernel.defconfig` sets no warning level, so both builds take
Kconfig's `WARN_WARNING` (`fiasco/kernel/src/Kconfig:839`), under which `WARN` and `WARNX(Error, ...)` print through `printf`
(`kern/warn.cpp:16-28`). A task can cause some of them: the receive that empties a reply slot still holding a caller
(`kern/receiver.cpp:234-238`, [The root service](#the-root-service)), a fault whose pager capability is invalid
(`kern/thread-ipc.cpp:258-262`, whether it fires in erXos's configuration unverified), and a kernel allocation that fails
(`kern/kmem_alloc.cpp:386-388`, at level `Error`); and `kdb_ke` prints without the debugger and carries on
(`kern/kdb_ke.cpp:1-12`). The kernel's console writes each piece of a line, and then its carriage return and newline, as one
call to the UART (`drivers/glue_libc.cc:20-36`), with interrupts off on that CPU and every other CPU's printing held off by
the printf lock (`kern/libc_backend_lock.cc:19-39`). On the 16550 kind, which the mini UART's driver is
(`lib/uart/uart_bcm2835.h:24`), the write sets `IER` to 0 for the whole call and polls `LSR` before each byte
(`lib/uart/uart_16550.cc:96-99,113-123`), and a read of `LSR` clears the receiver's overrun bit
([design-live.md](design-live.md#lost-input)). A 60-byte line takes about 5 ms at 115,200 baud and the mini UART's receive
FIFO fills in 0.7 ms, so input that arrives meanwhile is lost and the driver never learns of the loss. The PL011's write
leaves its interrupt mask alone (`lib/uart/uart_pl011.cc:113-116`) and its FIFO keeps each character's error bits, but the
line still lands among the driver's output at any byte. The harness fails a boot on the reply-slot warning
(`tools/lib/erx/qemu.rb:633-639,743`), so that line has a consumer and must still arrive.

So once the console's driver can hold the UART, the kernel writes it only to stop the machine, for every UART kind. The
construction is one console in front of the UART's, the kernel's **ring console**, through which every line the kernel
prints passes, and one value it owns, the **route**: `uart`, `ring` or `closed`. Two rules make the rest follow: a line
leaves the ring only whole, and the route closes before a stop prints its first byte.

* **One way to the UART.** The fork registers the ring console with the kernel's console multiplexer in the UART console's
  place, wrapping it (`kern/kernel_uart.cpp:147-170`, `init_filter_console`, with and without the debugger), and gives it the
  UART console's attributes and input, so the multiplexer's exclusive modes and the debugger find the UART as before. Under
  `uart` and `closed` its write passes the text to the UART; under `ring` it appends the text to its ring and returns. Every
  line the kernel prints goes through that write, whoever printed it: a `WARN`, `kdb_ke`, a panic, and the bytes the root
  or `sigma0` write through `l4_vcon_write`, which `Vlog::log_string` puts through the same console a character at a time,
  taking the printf lock for each (`kern/vlog.cpp:81-108`).
* **Who moves the route.** It starts at `uart`. Two operations of the kernel's log object move it. **Take** (`Vlog`
  operation 4, after Fiasco's 0 to 3, `kern/vlog.cpp:31-37`) moves `uart` to `ring`, leaves `ring` as it is, and returns the
  ring's whole lines; under `closed` it returns an empty reply, no line and no loss count, and leaves the ring and its
  count to the close's write-out, so a take never hands out the rest of a line the write-out has begun, whatever lock
  the glue holds across it. **Close** (operation 5) moves any route to `closed`. Both need the log object's `CW` right, as its read does, so a
  copy with fewer rights can do neither. The root and `sigma0` hold the log
  object (`kern/std_workload.cpp:43-48,73-78`; a task holds none, `liberx/backend/fiasco/task_start.c:95-96`); that `sigma0`
  calls neither rests on `sigma0` being the boot's own trusted code, not on a check. The kernel also closes the route
  itself, at the head of each of the four functions a stop's report begins in on AArch64, before the report's first byte:
  `panic` (`kern/kernel_panic.cc:13`) and `assert_fail` (`kern/assertion.cpp:12`), the only callers of
  `Thread::system_abort` and so of `terminate` (`kern/thread.cpp:1480-1486,1550-1551`); `Trap_state::dump`
  (`kern/arm/64/trap_state-arm.cpp:83`), which every trap report ahead of a panic calls (`kern/arm/64/thread-arm-64.cpp:91,104`,
  `kern/thread-ipc.cpp:1064`, and the release kernel's trap handler, `kern/arm/thread-jdb.cpp:122-125`); and the
  development kernel's `Jdb::open_debug_console` (`jdb/jdb.cpp:751-757`), where the debugger takes the console on every
  way in (`jdb/jdb.cpp:1328`), a development kernel's `kdb_ke` among them, a `brk` (`kern/arm/64/kdb_ke-arm.cpp`) into
  `Thread::call_nested_trap_handler` (`kern/arm/64/thread-arm-64.cpp:110-111`); a breakpoint the debugger only logs
  returns before it (`jdb/jdb.cpp:1292-1297`) and leaves the route as it is. So a stop's report never enters
  the ring: neither a full ring nor a take on another CPU can hold it back, and it reaches the UART with no running log
  service or driver. `closed` is final: nothing moves the route back, so a take that races a stop cannot hide the stop's lines.
* **Closing writes the ring out.** Holding the printf lock, the close sets the route to `closed` and then writes the ring's
  whole lines to the UART in the order the kernel printed them, each in the form a take gives the log: `fiasco: `, the line
  through the log core's one escaping function (`erx_log_escape`, `include/erx/log.h`, which `erx_cores.a` already holds),
  and a carriage return and newline, after a line `fiasco: N kernel lines lost` if the ring lost any. Bytes the root or `sigma0` wrote
  after the handoff, a development build's test task's among them, the only bytes from outside the kernel the ring can hold,
  are escaped on that path as on the take's. A line still open in the ring is written out as the ring's last line, in the
  same form, and counts nothing. The close ends any drop, so the report the stop prints next goes out raw and whole, as the kernel's own text, though `panic`
  begins it with no newline ahead of it (`kern/kernel_panic.cc:13-24`). Setting the route first makes a
  close that a stop inside the drain reaches again find `closed` and do nothing.

The ring, the route, the line framing, the close's rendering and the reading of a take's reply are one pure C17 core,
`kernel/core/console_ring.c` behind `include/erx/core/console_ring.h`, which Fiasco links through `erx_cores.a` and the
root links as well, so the reply's layout has one source. Fiasco's printf lock is its only lock: every write already holds
it, and the glue takes it for a take and a close, so the three are serialized across CPUs with no lock of the core's own.
A take holds it for a copy of at most one reply. A close holds it, with interrupts off on its CPU, for the ring's 4 KiB
written out: about 0.4 s at 115,200 baud for printable text and at most about 1.6 s when every byte is escaped, which the
machine's end and a stop can spend.

* **Whole lines.** The kernel's writes are not lines: the console writes a line's body and its carriage return and newline
  as separate writes (`drivers/glue_libc.cc:20-36`), `printf` writes through an 80-byte buffer
  (`lib/libc/src/stdio/vfprintf.c:409`), and the root's bytes arrive a character at a time. So the core frames them itself.
  It keeps the start of the line still open at the ring's tail, and a write that would overfill the ring, or make the open
  line longer than `ERX_CONSOLE_RING_LINE_MAX`, takes the open line's bytes back off the tail, counts one lost line and
  drops what follows in the ring up to and including the next newline. A take that moves the route from `uart` to `ring`
  while a line is open on the UART drops that line's rest the same way. A drop holds only on the `ring` route: a close
  keeps a line open in the ring as the ring's last line, which its write-out gives whole as far as the kernel printed
  it, and ends the drop, so every write under `uart` or `closed` reaches the UART whole, and the core's write answers
  only whether the caller writes the whole text to the UART. The rest of that line, if it arrives after the close,
  reaches the UART raw after the stop's report has begun; the stop's report is worth more than that line's tail. Every line a take hands out, and every line of a close's but the last, is then a whole line of the kernel's
  output, and a loss is always a whole
  line, counted once: no prefix of one line ever joins the rest of another. Lines that two CPUs' separate `printf` calls
  build together, or that the root's characters split, come out as the kernel printed them, as they did on the UART.
* **The bound.** The ring holds `ERX_CONSOLE_RING_BYTES`, 4,096, and never overwrites what it holds, so the lines that
  arrive are the first of a burst, which say most about it. A line holds at most `ERX_CONSOLE_RING_LINE_MAX` bytes, its
  carriage return and newline included, equal to `ERX_CONSOLE_RING_REPLY_BYTES`, so any whole line fits one reply; and
  `fiasco: ` with such a line escaped at four bytes a byte fits a record's text, `ERX_LOG_TEXT_MAX`, which the core states
  as a static assertion.
* **A take's reply** is in the caller's message registers: the lines lost since the last take, the number of bytes that
  follow, and the bytes, at most `ERX_CONSOLE_RING_REPLY_BYTES`, the 61 words of Fiasco's 63 message words
  (`L4_UTCB_GENERIC_DATA_SIZE`) left after the two counts. They are whole lines, as many as fit; the open line stays for a
  later take or the close.
* **The root's side.** Every `erx_log_take` of the service, the first included, runs exactly one kernel take, ahead of its
  copy. The core's line reader gives each line without its carriage return and newline and skips empty ones (each `WARN`
  opens with a newline). The service logs each line as a kernel record of level `warning` through the log core's
  `erx_log_bytes`, which adds a string-literal label and then exactly the bytes given, each through `erx_log_escape`, NUL
  bytes included, so nothing is cut short at a NUL as `%.*s` would cut it; a kernel line reaches the console and the stored
  kernel lines as printable ASCII, its colour sequences as `\x1b[31m`, as the untrusted-text rule asks of every sink
  ([design-log.md](design-log.md#the-kernels-records)). A count above 0 becomes a record of its own ahead of the lines,
  `fiasco: N kernel lines lost`, so a loss is never silent. These records join the log before the take copies, so the same
  take hands them to the log service.
* **What one take adds** to the log is bounded by the reply. A non-empty line takes at least three bytes of it, so a reply
  gives at most 162 lines; a record is its 32-byte header and its text padded to 8, and a line of one byte, the costliest
  for each byte of the reply, is a 48-byte record. One take adds at most 162 such records and the loss record, 7,848 bytes
  of the log's 64 KiB ring, with a copy, an escape and a record write per byte as its work.

What happens on each path:

* **A take after the first** finds `ring` and only drains. The log service takes every 100 ms, and again at once while a take
  fills its window ([design-log.md](design-log.md#the-kernels-records)), so a whole line reaches the log at the first take
  after its newline; a burst longer than one reply drains over several takes, 488 bytes each, and a line still without its
  newline waits for it.
* **No take.** A test root, which runs no log service (`test/guest/native_libc_test`'s among them), a partial
  boot, which starts no console, and a boot whose log service never makes its first take leave the route at `uart` for the
  whole run: the kernel writes the UART as upstream does, and a test task's bytes reach it unchanged. No console driver runs
  in the first two; for the third, FD26 publishes what sharing costs. The route moves in the same `service_log_take` as the
  log's sink, so it holds the same ordering against the driver's start, and the `TODO.md` item on that handoff covers both.
* **The log service stops.** Takes stop, the ring fills, and further lines are counted. The restarted service's first take
  drains the ring and logs the count. If its supervisor gives up past its restart intensity, the ring's lines and its count
  reach the UART when the machine ends.
* **The driver stops.** The route stays `ring`: the log service goes on taking, the kernel's lines go on reaching the log, and
  the console shows them once its driver restarts; the UART is silent meanwhile, as it is for every other record.
* **A panic, a failed assertion or a kernel trap** closes at its report's first function, as above, and the report follows
  the ring's lines on the UART. A line printed before the stop that a take on another CPU had already moved into the root's
  log, and which the console had not yet written, is lost with the root's other untaken records when the machine resets
  (FD26).
* **The debugger**, which only a development kernel has, closes the route where it takes the console,
  `Jdb::open_debug_console`, ahead of its own access to the UART: it disables the UART's receive interrupt before it stops
  the other CPUs (`jdb/jdb.cpp:755`, `Jdb::wfi_enter`, `jdb/arm/jdb-arm.cpp:61-66,117`), and a debugger entered from a
  panic finds the route closed already. A breakpoint it only logs never gets there. The console's driver is the UART's
  only user until then and not after, a limit of development builds that FD26 publishes: the debugger keeps upstream's
  resume (`jdb/jdb.cpp:1464-1470`), and the resume after a `kdb_ke` sequence run from kernel context, which no operator
  makes (`jdb/jdb.cpp:1343-1359`), and from there to the machine's end the kernel writes the UART beside the
  driver. Leaving the debugger also turns the UART's receive interrupt on under the driver: `Jdb::wfi_leave` enables it
  unless the serial input mode is `Serial_input_noirq` (`jdb/arm/jdb-arm.cpp:69-75,140`), and the mode is
  `Serial_no_input`, Fiasco's default (`kern/config.cpp:41-45,246-247`). On the PL011 the entry and the leave both clear
  the UART's pending interrupts and its error flags (`lib/uart/uart_pl011.cc:120-133`), so an error the driver had not
  yet read is lost unmarked. A development kernel started with `-wait` or `-jdb_cmd` enters the debugger before user mode
  (`kern/kernel_thread.cpp:194-217`), so the route is `closed` before the first take and the whole run writes the UART as
  upstream does. Resuming is otherwise an operator's choice in a development build, and a harness run that enters the debugger ends
  at its deadline.
* **The machine's end.** Every end path takes the end through `end_take` (`liberx/backend/fiasco/end.c:42-46`), which
  `erx_fiasco_end`, the refusals and the watchdog's end all call (`end.c:79-83,96-99`), and the winner of its exchange closes
  the route at once, before the end's first `l4_vcon_write`, on whichever thread it runs: the close is a kernel operation
  under the printf lock and needs no ownership of the root's log. So the ring's lines come out first, then the log's untaken
  records, the crash record and the last line; a kernel line still in the ring is written ahead of untaken log records older
  than it, the one place where the two orders differ.
* **A hang.** A hang of Fiasco, or a stop that only the hardware watchdog ends, loses what the ring holds, as it loses the
  root's untaken records (FD26).
* **A burst.** A task that makes the kernel warn in a loop fills the ring, its lines past the ring are counted, and each
  take adds at most the bound above; the records push the log's oldest records out as any flood does, which the log counts
  for every reader that loses them. Kernel records have no per-space rate (`erx_log_format`, `include/erx/log.h`), and the
  kernel's lines get none either.
* **The root's own writes after the take.** An `l4_vcon_write` of the root outside the end path after the handoff reaches
  the ring and arrives as kernel records, escaped: a development build's test task's `task_write`, and a test task's crash
  frame. The root writes a task's frame, a record of about 915 bytes as 19 lines of up to 76 characters
  (`erx_crash_frame_line_count`, `kernel/core/crash_frame.c:85-93`), only for a space with no fault gate
  (`erx_fiasco_task_crash_write`, `end.c:164-177`, from `erx_fiasco_task_fault`, `service_task.c:1144-1150`, when
  `erx_fiasco_gate_fault` finds no gate, `fault_gate.c:171-172`), and only the launcher's root-only `test_space_create`
  (`service_task.c:392-398`) makes one: the null case of `erx_fiasco_gate_named` (`fault_gate.c:74-77`, which in the
  present tree serves every create) is taken for that create alone, and every other create (`service_task.c:428`)
  refuses `ERX_CAP_NULL` as its fault gate as it refuses any handle that names no gate. The domain library and a
  session already pass a gate (`liberx/system/dom_core.c:964-967`, `otp/erts/emulator/sys/erxos/erx_program_drv.c:822-826`). A space whose gate is destroyed has its later faults counted, not written
  (`fault_gate.c:186-197`). So no domain's or session's task writes a frame, and a test task's frame reaches the UART
  whole in the test roots that launch test tasks, which take no log; a test task launched after the handoff in a full
  development boot would have its frame arrive as kernel records, as its `task_write` bytes do, and the frame readers,
  which take a marker only as a whole line, would not find it ([design-kernel.md](design-kernel.md)). On erXos's kernel a
  space's fault gate is a handle with `SERVE` ([design-kernel.md](design-kernel.md)), and which status its
  `erx_space_create` returns for `ERX_CAP_NULL` is unverified.

The operations refuse nothing new: an operation number Fiasco's log object does not know is still `-L4_err::ENosys`
(`kern/vlog.cpp:209-222`), and the take writes only the caller's own message registers, so neither reads memory the caller
names.

## The Raspberry Pi 4

The Raspberry Pi 4 Model B runs this backend behind the same interface, on the same Fiasco kernel build as QEMU `virt`.
[design-platforms.md](design-platforms.md#raspberry-pi-4-model-b) describes the board, and
[plan.md](plan.md#1b-i-the-raspberry-pi-4-on-fiasco) the order in which it comes up. What differs from QEMU `virt` is
data, one `bootstrap` build, the random generator's read, and the kernel's other platform items, which this backend does not have:

* **Firmware and PSCI.** The Raspberry Pi firmware loads the bootable file as `kernel8.img` and TF-A 2.15.0's BL31 as
  the armstub, as it does for erXos's kernel ([Firmware](design-platforms.md#firmware)); no U-Boot runs. The kernel
  build is Fiasco's generic platform with PSCI (`CONFIG_PF_ARM_GEN`, `CONFIG_ARM_PSCI` in
  `config/fiasco/kernel.defconfig`), which finds the interrupt controller, the timer and PSCI's calling method in the
  device tree. BL31's PSCI starts the other CPUs, and `l4_platform_ctl_system_shutdown` reaches its `SYSTEM_OFF` and
  `SYSTEM_RESET` ([The end path](#the-end-path)). `SYSTEM_OFF` leaves the board halted in the firmware, which cannot
  turn it off, and the hardware watchdog the root armed resets it about 4 s later, so an end by `ERX_END_OFF` on the
  Pi 4 reboots the board and only cutting its power turns it off; a missed pet and a root fault reset
  ([The end path](#the-end-path)).
* **The hardware watchdog.** The board's power-management watchdog, a unit of the platform record
  (`config/platforms/raspi4b.json`) that the manifest gives the system domain, whose window only the root maps, armed
  and reloaded on every boot ([The watchdog](#the-watchdog)).
* **On-board pins.** The pin controller, `gpio` in the platform record, is a unit the manifest gives the system
  domain. After the watchdog and the mailbox are programmed and before any domain starts, the root sets the functions
  of the board's on-board pins from the manifest's `pins` rows of that controller, UART0's GPIO 30 to 33 to the Bluetooth
  controller, at the window the controller's row states and only once the firmware's tree confirms that window
  ([design-header-io.md](design-header-io.md#on-board-pins)). Only GPIO 28 to 57, banks 1 and 2, can be written, by
  construction: the pure core `kernel/core/bcm2711_pins.c` has a field for those pins alone, so no row reaches a
  header pin, the console's among them. The plan is taken whole or not at all, only the words that change are
  written, each with its reserved bits cleared, and all six are read back. The root reports one line,
  `erx: root task: on-board pins set: N rows`; or why it wrote nothing; or
  `erx: root task: on-board pins mismatch: ...` when the words were written but read back otherwise. A boot whose
  pins are not set goes on without them, except for a malformed manifest row: a controller row whose tree path is
  not a node path refuses the boot, as the watchdog's and the mailbox's rows do. This step is the implementation
  that the system domain's pin driver replaces: with it the root sets no pin, and the core, the root's selection of the manifest's
  `pins` rows and the report line go ([design-pinctrl.md](design-pinctrl.md#what-the-code-does-today)).
* **Entropy.** On the condition [Entropy sources](design-platforms.md#entropy-sources) states for the kernel's platform
  layer, the root also reads 32 bytes from the board's RNG200 random generator, waiting at most 100 ms, and seeds its
  generator from them, as that layer does on erXos's kernel. Where the generator is comes from one
  checked-in source, its row in the platform record (`config/platforms/raspi4b.json`, unit `rng`, the base and size
  `/soc/rng@7e104000` names, CPU address `0xfe104000` and `0x28` bytes; BCM2711 ARM Peripherals release 4 states the
  bus-to-CPU mapping, section 1.2.4, page 6, but describes no RNG200 registers, so the window is the device tree's,
  checked against the board's tree by the board tree's test), which reaches the root as a unit the manifest gives the
  system domain; the device is of no kind, so no record or window goes to any runtime. The firmware's tree only
  confirms it: the root maps the row's window only when the tree's enabled node at the row's path, of compatible
  `brcm,bcm2711-rng200`, names exactly that window (`erx_dt_registers`), as the framebuffer row's window bounds the
  framebuffer the tree places, so a tree cannot move the read onto another device's page. A manifest that gives the
  system domain no `rng` unit keeps the root off the generator. The root maps the register page through sigma0 and
  starts the generator if it is stopped
  (`liberx/backend/fiasco/rng200.c` over `kernel/core/rng200.c`). The banner names the source, or why it gave nothing
  ([the call table](#the-call-table)): a read that times out, or a tree whose node names another window or none,
  leaves the counter alone. The RNG200's registers and read sequence come from a clean-room facts record of the RNG200.
* **The card.** `sdcard.img` is the medium of `abi/medium.txt`, as QEMU `virt`'s medium is, laid out as
  [Slots and the boot-selection record](design-platforms.md#slots-and-the-boot-selection-record) describes: the
  record's partition, whose FAT16 data area begins with `autoboot.txt`; boot A, a FAT32 volume of the boot files below;
  boot B, empty; system A, the EROFS image of the slot's packages; system B, empty; the vault's partition; and the data
  partition with a fresh littlefs volume. `kernel8.img` and `autoboot.txt` are each placed contiguous at the layout's
  start sector (`medium_slot_boot_start`, `medium_record_select_start`) with fsimg's `place` option, so the harness and
  the slot writer find them without parsing FAT and the firmware finds them through FAT; the packer reads each placed
  file back through its cluster chain and refuses a chain that is not consecutive from the placement sector, ends early or runs on
  past the file's last cluster, a file that differs from the raw extent, and an `autoboot.txt` that is not
  the record's 64 bytes (`tools/lib/erx/pi_medium.rb`; seeded with a fragmented `kernel8.img`). Every byte no piece holds is zero, and
  `sdcard.img.xz` beside it is the card xz-compressed. The firmware boots this card only if the board's EEPROM
  bootloader reads `autoboot.txt` and honours `tryboot_a_b` and `boot_partition`; the board's port records the oldest
  bootloader version that does ([design-platforms.md](design-platforms.md#slots-and-the-boot-selection-record)). The
  Pi's development manifest gives the SD controller's unit to the domain that runs the block driver and littlefs at
  `/data`, as QEMU `virt`'s gives its block unit.
* **Boot files.** One directory, `boot/`, serves as the firmware's network boot root and holds the files slot A's
  FAT holds, written by `tools/erx pack --medium --platform raspi4b` beside `sdcard.img`
  (`tools/lib/erx/boot_partition.rb`): the firmware and its license; `config.txt`, written from the platform record,
  which asks for one 32-bit framebuffer with no overscan border and, on a development card only, the firmware's boot
  log on the console and the ARM's JTAG on GPIO 22 to 27; `cmdline.txt` on a development card only, holding
  `erx.hostlink=1`, which the firmware hands to the boot as `/chosen/bootargs` so that the root hands the host link's
  UART3 to the system domain ([The command line](#the-command-line)); BL31 and its license; the bootable file as `kernel8.img`;
  Linux's device tree for the board, compiled from its pinned source with its two serial aliases swapped, so that
  `serial0` names the console, with that source beside it; and the overlays `config.txt` names, whose sources erXos
  keeps in `hw/dts`, since mainline Linux has none (`tools/lib/erx/board_tree.rb`).
* **Under QEMU.** The same image, device tree and BL31 also boot on QEMU's `raspi4b` model under TCG, where QEMU's
  generic loader places them in place of the firmware and the harness gives the model's second serial port, the mini
  UART's, to the console; what the model checks and what it cannot is in
  [Bring-up under QEMU](design-platforms.md#bring-up-under-qemu). If BL31 does not run there, the model boots the
  image on one CPU through QEMU's own kernel loader, without PSCI.
* **Bootstrap.** The Pi has a `bootstrap` build of its own, for Fiasco's generic platform (`arm_gen`), whose RAM
  starts at 0 and which reads the memory map, the console's UART and PSCI's calling method from the device tree.
  Upstream links that platform's `bootstrap` position-independent; erXos's `bootstrap` runs only at its link address,
  so the Pi's is linked static at `0x200000`, where the firmware loads a 64-bit image with the boot protocol's header
  ([research](research-boards-storage.md)) and where BL31's stub header sends it, above BL31's reserved first 512 KiB, as QEMU
  `virt`'s is linked at RAM's base plus 2 MiB. QEMU `virt` keeps its `arm_virt` build
  (`config/fiasco/user.defconfig`), whose RAM starts at `0x40000000`. Fiasco's `rpi` platform, which asks the
  firmware's mailbox for memory and tells the boards apart by their CPU, is not used. The firmware enters the bootable
  file in a higher privilege mode than the kernel's, and `bootstrap` drops to the kernel's before it starts Fiasco;
  the boot probe confirms the entry state. The console is the mini UART (`brcm,bcm2835-aux-uart`), which `bootstrap`
  and Fiasco find by `/chosen/stdout-path`. BL31 rewrites that property to `serial0` (TF-A's
  `plat/rpi/rpi4/rpi4_setup.c`), and the firmware leaves the aliases as the card's tree has them, so the card's tree
  names the mini UART `serial0`, swapping Linux's two serial aliases, and the model boots that same tree
  ([design-platforms.md](design-platforms.md#raspberry-pi-4-model-b)). The kernel build already carries Fiasco's driver for it
  (`fiasco/kernel/src/lib/uart/uart_bcm2835.cc`, built under `CONFIG_PF_ARM_GEN_SELECT_UART_16550`, on by default);
  `bootstrap`'s UART library (`fiasco/drivers-frst/uart`) holds only the PL011 driver, so the Pi's `bootstrap` build
  imports Fiasco's 16550 and BCM2835 drivers into it and turns on `CONFIG_DRIVERS_FRST_UART_DRV_8250`. Both keep the
  baud divisor the firmware set ([design-platforms.md](design-platforms.md#raspberry-pi-4-model-b)): given a base rate
  of 0, `Uart_16550::change_mode` writes no divisor.
* **The platform record and the machine.** The Pi's platform record and development manifest sit beside QEMU `virt`'s
  and have their format: units, device paths, windows, lines, `ram_bytes`, `fiasco_reserve` and `root_withheld`
  ([The Phase 1 manifest check](#the-phase-1-manifest-check), "The root startup rule"; the Pi's is measured on its own boots), and RAM's first
  address, which is 0 on the Pi and `0x40000000` on QEMU `virt`. Every tool that builds or boots an image takes the
  record and its `ProductionImage::Machine` as a parameter, never a constant of QEMU `virt`. The record's `ram_bytes`
  is the smallest RAM the port boots on; the manifest check proves the manifest against it, and a board with more RAM
  boots the same image with a larger pool. The root's place follows [Boot](design-platforms.md#boot)'s arithmetic
  from RAM's first address, clear of BL31's reserved memory and the device tree, as the boot probe finds them; the
  bootable file does not bound it, since bootstrap moves an archive the root lands on behind the root
  ([Boot handoff](#boot-handoff)). Where the root maps the kernel information page is part of the backend's address layout, above all RAM
  beside the device window, so no platform record carries it.
* **Devices.** The Pi's DMA devices are not coherent, so the device NIF cleans and invalidates as
  [design-device-dma.md](design-device-dma.md) orders for such a device; QEMU `virt`'s are coherent, and their
  records say so, from the device tree QEMU writes. Each DMA device's coherence and DMA range come from the device
  tree the firmware hands over ([design-device-tree.md](design-device-tree.md)); the device NIF hands the device only
  addresses `erx_mem_dma_addr` gives through that range, and a device whose range is absent, or whose contiguous
  memory would lie outside it, gets no DMA memory, with a line naming it. Ethernet sees RAM at the CPU's addresses and gets 1 MiB, 256 receive and 256 transmit buffers of
  2 KiB, its descriptors being registers. The SD controller gets DMA memory at the range the firmware wrote for the
  board's revision, which the root reads from the tree. The firmware's
  framebuffer lies in memory the firmware keeps out of the RAM it reports, so it is a physical window of the display
  domain's record, mapped as device memory, which its writes reach without cache maintenance; the root takes where
  it lies, inside the window of its manifest row, and its geometry from the `simple-framebuffer` node, if the firmware adds one, which the board pass
  confirms ([design-device-tree.md](design-device-tree.md#facts-into-records)).
* **What the board does not get here.** The kernel's platform items, which M12 brings on erXos's kernel: the
  firmware does not start the hardware watchdog, even on a board that runs unattended, since nothing under Fiasco would
  reload it before the root's watchdog thread starts and arms it, so a hang before then is caught only by the harness's
  deadline, after which its power is cycled by hand; there is no crash region, so the crash record reaches the
  console alone; the trial request is the root's mailbox request of [The end path](#the-end-path), and the boot value is what `/chosen/bootloader` says;
  and there is no device secret, so `sealing` stays `none`. Together they are FD29. The
  random generator is not among them: the root reads it (the Entropy item above).
* **The watchdog's numbers.** The board runs natively, so the harness gives it the design's defaults, as it gives
  HVF, and gives the `raspi4b` model the numbers it gives TCG ([The watchdog](#the-watchdog)).

## The Raspberry Pi 5

The Raspberry Pi 5, a 4 GB board, runs this backend as the Pi 4 does, on the same Fiasco kernel build.
[design-platforms.md](design-platforms.md#the-raspberry-pi-5-on-fiasco) describes the board under Fiasco,
[design-rp1.md](design-rp1.md) its I/O controller, and [plan.md](plan.md#1b-j-the-raspberry-pi-5-on-fiasco) the order in
which it comes up. What differs from the Pi 4 is data and two platform items:

* **Firmware and PSCI.** The firmware loads the bootable file as `kernel_2712.img` and starts it through its own BL31,
  so no armstub is shipped and no TF-A is built for the board. The kernel build is the Pi 4's, Fiasco's generic platform
  with PSCI, which finds the interrupt controller, the timer and PSCI's method in the tree. The end path is the Pi 4's.
* **Bootstrap.** The Pi 4's `bootstrap` build, `arm_gen` with the PL011 console and a fixed link at `0x200000`, serves
  the Pi 5 unless the boot probe shows that the firmware loads the file elsewhere; `config.txt` sets
  `kernel_address=0x200000`. `bootstrap` reads no UART clock from the tree, so the console keeps the firmware's divisor
  whatever the tree says of the clock ([design-platforms.md](design-platforms.md#the-raspberry-pi-5-on-fiasco)).
* **The hardware watchdog.** The same root thread arms and reloads the BCM2712's power-management watchdog at
  `0x10_7d200000`, through the window the platform record (`config/platforms/raspi5.json`) names, with the Pi 4's
  register sequence ([The watchdog](#the-watchdog)); the board probe's hang test confirms that the block behaves as the
  BCM2711's.
* **Entropy.** The root reads the RNG200 at `0x10_7d208000` as on the Pi 4; the tree's node keeps the Pi 4's
  compatible.
* **The MSI frame.** The platform record names the MIP as the board's `msi_frame`: peripheral `bcm2712_mip`, base
  `0x10_0013_0000`, first line 160 (SPI 128), 64 lines, serving `pcie2`. The backend's `ERX_IRQ_MSI` is QEMU's: data
  0, which the packer derives, and the doorbell `0xff_ffff_f000`, which the root derives at boot from `pcie2`'s inbound
  windows in the tree the firmware handed over; before it binds any line, the root makes the frame's six start
  writes through the frame's page, which only it maps, as it maps the watchdog's block
  ([design-pcie.md](design-pcie.md#the-msi-frame-on-fiasco)).
* **Devices.** The BCM2712 bridge `pcie2` in the PCIe domain, RP1's unit in the `rp1` domain, the SD controller in the
  storage domain, the console in the system domain. RP1 masters DMA with no IOMMU, so the `rp1` domain is in the trusted
  base, as every Pi 4 DMA device's domain is (FD12).
* **What the board does not get here.** The Pi 4's list, FD29: no firmware-started watchdog, no crash region, the trial
  request through the root's mailbox call, no device secret.

No new downside comes with the board: what it lacks against erXos's kernel is FD12's and FD29's, as on the Pi 4.

## Deterministic mode

`erx.det=1` is one CPU, TCG with instruction counting, the interpreter. The harness runs QEMU with `-smp 1`, `-icount shift=0,sleep=off` (without `shift`, `-icount` counts nothing), `-rtc base=2026-01-01,clock=vm`, so the real-time clock starts at a fixed date and runs on the instruction count, and the `virt` machine's `dtb-randomness=off`, so the device tree carries no random seeds; `Erx::QemuPlan` adds them exactly when the kernel command line carries `erx.det=1`, and refuses that word under HVF or on more than one CPU. Fiasco's tick comes from
the architecture's generic timer, which instruction counting makes a function of the instructions executed; the time page, deadlines and entropy derive from
that counter, since the tree carries no seed. ERTS runs one scheduler and the interpreter, in every domain: when the root's boot
information carries `ERX_BOOT_DET`, the domain library starts each domain on the interpreter image, whatever image its
specification names, so no domain gets a JIT space and no code depends on BeamAsm's addresses or hash order. The watchdog's step is off.
Deterministic mode is a development build's ([The command line](#the-command-line)), so the entropy refusal, which a tree
without seeds triggers in a release, never meets it. The comparison starts at erXos's banner, or at the
root's first line if Fiasco's own boot proves not deterministic, recorded as a difference (FD26).

## What Phase 1 code must not assume

* **Handles are opaque**, not Fiasco capabilities and not stable across a boot.
* **A committed page is present here, and Phase 2 populates lazily.** Read no timing or fault counts from it. (FD7)
* **`erx_device` keeps physical addresses behind the DMA profile**, and nothing else sees one.
* **Faults reach code as crash records**, never as Fiasco's exception messages.
* **Callers check `ERX_ENOTSUP`**, and show `unsupported` and `partial` as such.
* **No thread is destroyed from outside or stopped.** ERTS's use of threads needs neither.
* **A doorbell's latency is Fiasco's.** A trigger is the ringer's own Fiasco invocation and its wake goes through the
  receiving task's dispatcher, so no number measured here decides batching or a native fast path on erXos's kernel
  (FD16).
* **A program's start costs one service request per object.** Whether a start needs a cheaper path than one kernel call per
  object is decided on erXos's kernel, never from this backend's numbers (FD17).
* **The hostile suites are written against the interface.** Their verdict cases (a funnel's verdict on a malformed or
  forged frame, a server's on a malformed request, a driver's on a malformed descriptor) run on every build, their
  confinement cases and memory walls run on a release build in their Fiasco set, and a case that checks what only
  erXos's kernel bounds reports `unsupported`, naming its downside ([Security on Fiasco](#security-on-fiasco)).
* **An object can go with the task that created it** (FD5).

**A service's request interface is portable.** This is the rule for a service author:

> A service's request interface is the one its design document gives, whatever Phase 1 enforces. A client reaches a service by a pid it was introduced to (the
> facet the domain library hands it at start, or the pid in a reply), never by a registered name of another application, `whereis`, or a module's `start_link`
> return kept across applications. A request and its reply carry portable terms only: atoms, numbers, binaries, lists, tuples, maps, pids and references; never a NIF
> resource, a fun, a port, an ETS table identifier, a `liberx` handle or a Fiasco value. A grant is named by the identifier the server issued for it and nothing else.
> A service reads no table, ETS or `persistent_term`, that another service owns. Local message delivery is Phase 1's transport and a frame on a lane is Phase 2's;
> neither appears in the request's shape. Then moving a service to another domain changes its introduction, not its callers.

The file namespace ([design-files.md](design-files.md)) and the shell's command context ([design-shell.md](design-shell.md)) are the two interfaces to follow first.

## The release's Fiasco build

**Configuration.** The release configuration is an exact allowlist, which
`tools/lib/erx/fiasco_config.rb`'s check holds as it holds the development one, so an option off
the list fails the check. It turns the debugger off, so no capstone is compiled; `jdb_object.cpp`, which
upstream's `Modules.generic` lists for every kernel, the patch below takes out of the release kernel. It keeps the fixed-priority scheduler; keeps `EXPLICIT_REPLY_CAPS`, which
[the pause](#threads-bands-and-stops) needs, and `IOMMU`, for a platform that puts a device behind
one; turns off `PAGEFAULT_TRAMPOLINE`, `ALIEN` and `IRQ_DIRECT_INJECT`, which no consumer needs
and which widen what a thread can do with itself ([Who holds what](#who-holds-what)); and turns off
`UART_CHECKSUM` and every other option with no consumer. A release build that turns the debugger on
fails the check. Development builds keep the debugger.

**Toolchain.** Fiasco (kernel and `bootstrap`) and L4Re (`sigma0` and `l4re-core`) are built with
LLVM: clang, `ld.lld` and LLVM's binary tools (`llvm-ar`, `llvm-nm`, `llvm-objcopy`,
`llvm-objdump`, `llvm-ranlib`, `llvm-size`, `llvm-strip`) installed beside clang, not with a GNU
cross compiler and binutils. `tools/lib/erx/fiasco_toolchain.rb` (`FiascoToolchain`) takes clang
from `ERX_CLANG` and `ld.lld` from `ERX_LLD`, the two variables every other erXos build uses.
`CROSS_COMPILE` is the constant `aarch64-none-elf-` and only names clang's `--target`; no program
of that prefix runs. The toolchain reaches the inherited make systems through `Makeconf.local`
files, never the make command line: the kernel build directory's (`CC`, `CXX`, `CPP=clang-cpp`,
`LD=ld.lld` and the `llvm-` tools) and the assembled L4Re source's (`CLANG` as clang's directory,
`LD = ld.lld -m $(LD_EMULATION)` and the `llvm-` tools). The fork carries eight small edits for it:

1. The kernel's `Makeconf` drops `ASFLAGS-clang += -no-integrated-as`, so clang assembles `.S`
   files with its integrated assembler.
2. The kernel's `Makeconf` uses the `CPP` that `Makeconf.local` names as given, with no
   `CROSS_COMPILE` prefix.
3. `mk/mk/Makeconf` admits clang 23 in `CC_WHITELIST-clang`.
4. `kern/arm/Makerules.KERNEL.arm` keeps `.dynsym` and `.dynstr` in the raw `bootstrap` image,
   because `llvm-objcopy` refuses to remove them while the dynamic relocation section links to
   them (they lie inside the loaded range, so only those bytes change).
5. The AArch64 `bootstrap` relocates itself under LLD as under GNU ld: `_start` takes its link
   address from `_start_link_addr`, an absolute symbol of `bootstrap.arm.ld` that no relocation
   touches, rather than from its GOT slot, a load LLD may relax into the run-time address of
   `_start`; LLD gets `--apply-dynamic-relocs`, so every relocated word holds its link-time
   value, which a bootstrap without an MMU needs because it relocates nothing; the relocator
   reaches `_DYNAMIC` through a namespace-scope hidden declaration, which clang addresses
   PC-relatively; and the relocator names the format it applies in `bootstrap_reloc_tag`, so
   `bootstrap.arm.ld` fails the link on a dynamic relocation of the format the relocator would
   skip without a word.
6. Only whole names of the raw `bootstrap` are exported into `bootstrap.fiasco.sym`: its
   `bootstrap_sed` pattern is anchored at the end of the name, so `_start_link_addr` is not
   taken for `_start`.
7. `koptions.cpp`'s initializer of the kernel options gives the two fields erXos adds to them
   (`erx_pad`, `erx_handoff`), which clang otherwise warns are missing, so the kernel builds
   without a warning.
8. `bootstrap`'s linker scripts (`ARCH-arm64/bootstrap.ld.in`, `ARCH-arm/bootstrap.ld.in` and the
   AArch64 EFI script) put the UART device table (`DEVS` of `ldscript.inc`, the
   `.data.l4redevice` pointers between `__L4RE_DEVICE_BEGIN` and `__L4RE_DEVICE_END`) first in
   `.data`, as the kernel's `kernel.arm.ld` does, so the first rule a section matches puts every
   entry in the table by its section name, under GNU ld and `ld.lld` alike. They do not keep the
   entries out of the generic `.data.*` rule with `EXCLUDE_FILE(*libdrivers_uart.a)`: in an
   `ld.lld` link that rule takes the archive's `.data.l4redevice` sections, as its link map shows,
   and leaves the table empty, and the generic platform (`arm_gen`, the Raspberry Pi 4's) finds
   its console UART only in that table.

**Patches.** These are the changes the release's Fiasco build makes to what Fiasco's kernel does,
each small and contained in the fork. An entry names its test where it has one, and says so where
no test can drive the change:

* **The clean-room interface header.** The tree's `src/kern/kobject_rpc.h` is not Fiasco's: it is
  an erXos-authored, MIT-licensed clean-room replacement of the GPL-2.0-only original, which the
  fork removed without opening it (`fiasco/kernel/ORIGIN.md` records the file under `changes`), so
  every build compiles the replacement. It is
  written from the clean-room facts record (erxos-history `cleanroom/fiasco-gpl-facts.md`, commit
  `2a1e35e`) and from what the MIT files that include it call; no one reads the GPL header to write
  it, and no agent that has read it writes it.
* **`jdb_object.cpp` out of the release kernel.** Upstream's `Modules.generic` lists the debugger's kernel object for every
  kernel, whatever `CONFIG_JDB` says, so turning the debugger off would leave the
  GPL-2.0 file compiled. The fork lists it only for a kernel built with the debugger (`fiasco/kernel/src/Modules.generic:62-63`), a one-line edit: no MIT file of
  the kernel refers to it, and capability slot 10, which it fills, is then empty, which the boot workload
  (`std_workload.cpp`) already allows. `sigma0`'s calls that name its objects then fail; that `sigma0` ignores the
  failure is unverified, and a boot of the release kernel checks it. These facts come from a clean-room facts record of
  the file, written by an agent that writes none of erXos's code or documents (erxos-history
  `cleanroom/fiasco-gpl-facts.md`, commit `2a1e35e`).
* **Writable or executable.** Fiasco's map refuses a user mapping that would be writable and
  executable at once into any task but the two its boot workload creates (`std_workload.cpp`),
  `sigma0` and the root: `sigma0` hands out RAM read, write and execute
  (`l4re-core/sigma0/server/src/memmap.cc:96,125`), and the root's image keeps that mapping
  (FD10). So for every other task the property stops resting on the root's code alone (an estimate
  of tens of lines, unverified). It covers one mapping: a page writable through one mapping and
  executable through another, and a device's write to a page mapped executable, stay FD8.
* **Eager FP switching.** The fork deletes Fiasco's lazy FP switching: its `LAZY_FPU` option and every
  section it guarded are gone from every architecture, so every switch saves the FP and SIMD state of
  the thread it leaves and restores that of the thread it enters, as erXos's kernel does
  ([design-kernel.md](design-kernel.md), "No FP or SIMD in the kernel"), and no thread's registers
  stay in the unit while a thread of another space runs. SVE
  stays trapped. `tools/lib/erx/fiasco_config.rb` forbids `CONFIG_LAZY_FPU` and `CONFIG_ARM_SVE`
  in every configuration; `test/integration/fiasco_config_test.rb` resolves the fork's Kconfig and
  its seeded case puts the option back with the `select` from `PERFORMANCE` that set it whatever the
  defconfig said, which the check must catch. The switch itself has the *FP state* case of
  [The release's cases](#the-releases-cases).
* **Branch-predictor hardening at entry, carried only if it costs nothing measurable.** The patch calls the
  firmware's workaround (`SMCCC_ARCH_WORKAROUND_1` against branch-target injection, `SMCCC_ARCH_WORKAROUND_3`
  against branch-history injection) at every entry from user mode and at every switch between address spaces, on the
  CPUs the firmware reports as needing it, as erXos's kernel does
  ([design-arch-aarch64.md](design-arch-aarch64.md#speculation-mitigations)), and closes FD32. Whether the fork carries
  it is settled by one measurement: the null request of [Measurements](#measurements), timed on the Raspberry Pi 4,
  whose Cortex-A72 is the affected CPU ([Read in source, never run](#read-in-source-never-run)), on a release build
  with the patch and one without, each run at least ten times. The patch is carried when the patched build's median round
  trip lies within the spread of the unpatched build's medians across its runs; otherwise it is not, and FD32 stays a
  published downside. QEMU numbers do not settle it, since the cost is the firmware's call on the affected CPU. If the
  firmware reports neither workaround, the patch has nothing to call and FD32 stays published as well; whether 0.2's BL31
  build turns them on is unverified. If carried, its case, on the Raspberry Pi 4's manual checklist: the kernel's boot
  log names the workarounds the firmware reported and the entry uses; seeded failure: the firmware's answer ignored, so
  the log names none and the case fails.
* **The boot handoff.** The kernel boots from erXos's boot image and greets as erXos
  (`arm/startup-arm.cpp`, `banner.cpp`, `koptions-def.h`, and `fiasco/kernel/src/erx/erx_handoff.cpp`
  and `fiasco/kernel/src/abi/kip.cpp`),
  as [Boot handoff](#boot-handoff) describes; every boot test drives it.
* **An SError from user mode.** Upstream's SError vectors from user mode enter
  `Thread::arm_serror_handler`, which counts the error and returns, so it ends nothing. The fork's
  (`arm/64/ivt.S`) enter `Thread::arm_serror_user_entry`
  (`arm/thread-arm.cpp`), which counts it and sends the running thread an exception carrying the
  SError's syndrome, as `arm_esr_entry` does for an exception class it does not handle; a thread of
  `sigma0`, which has no exception handler, only has it counted. The root takes the exception as
  the fault kind `async_error`, so the error ends the task presumed its source, except in the root
  and `sigma0` (FD33, and [Open decisions](#open-decisions), which says what happens there). `arm_esr_entry` also clears the exception record's fault
  address, so no record carries an earlier frame's. QEMU `virt` raises no SError a guest can cause,
  so no test drives the entry; `test/host/fiasco_exception_test.rb` tests the root's choice of fault
  kind, and its seeded failure, every class taken as undefined, makes it fail.
* **A kernel trap without the debugger.** Upstream's `Thread::call_nested_trap_handler` for a
  kernel without JDB (`arm/thread-jdb.cpp`) dumps the trap state, kills the current thread and
  returns to the faulting instruction, so the CPU traps again while the others run on. The fork's
  dumps the state and panics, so a kernel trap is fatal on a release kernel as on a development
  one, whose JDB stops every CPU ([Boot handoff](#boot-handoff)). Its test is the kernel-trap case
  of [The backend's cases](#the-backends-cases), on a test kernel with a seeded trap; seeded
  failure: upstream's handler, under which the trap dumps repeat.
* **The kernel's lines after the handoff.** Upstream's kernel writes every line it prints to the console UART by
  polling, whenever it prints, so its warnings land among the console driver's output and, on the mini UART, lose input
  unmarked. The fork's ring console stands in front of the UART's and sends the kernel's lines to a 4 KiB ring from the log
  service's first take until the machine stops, and the root drains the ring into the log as kernel records at every take
  ([The kernel's lines](#the-kernels-lines)). The C++ is the ring console and its registration in place of the UART's
  (`kern/kernel_uart.cpp`), the take and the close in `Vlog::kinvoke` (`kern/vlog.cpp`), and one call closing the route at
  the head of each function a stop's report begins in: `panic` (`kern/kernel_panic.cc`), `assert_fail`
  (`kern/assertion.cpp`), `Trap_state::dump` (`kern/arm/64/trap_state-arm.cpp`) and the development kernel's
  `Jdb::open_debug_console` (`jdb/jdb.cpp`), all reaching the core through the glue file
  `fiasco/kernel/src/erx/erx_console_ring.cpp`, whose references to the printf lock and the console base class are lines
  of `fiasco/erx_glue_imports.txt`: an estimate of about 80 lines, unverified. The route machine, the ring with its line
  framing, bound and loss count, the close's escaped rendering, the reply's layout and its line reader are the C17 core
  `kernel/core/console_ring.c`, in `erx_cores.a`, which the root links too; the log core gains `erx_log_bytes`, a label and
  a length of bytes, escaped, beside `erx_log_format`. The root's side, one kernel take in `service_log_take` and the
  close in `end_take`, is about 30 lines, and the backend's space create refuses `ERX_CAP_NULL` as a fault gate
  outside `test_space_create`, with the guests that pass it (`test/guest/native_irq/guest.c:536`,
  `native_space/guest.c:793`, `native_task/guest.c:151`) passing a gate or using the test create. Its tests are the *Kernel lines* and kernel-trap cases of
  [The backend's cases](#the-backends-cases) and the cores' host tests.
* **An unbound pin's interrupt.** `Irq_chip_gen::detach` masks and clears a pin without waiting
  for a CPU that has already acknowledged its interrupt, so upstream's `Irq_chip::handle_irq`
  (`irq_chip.cpp`) can dereference a null object when a domain's interrupt is detached as it fires.
  The fork ends that interrupt at its chip and the chips upstream of it and returns, so the CPU's
  priority drops. No test drives it: the race does not fire reliably, and the build has no
  in-kernel test. A handler whose object was bound to the software chip by then still leaves that
  CPU's interrupt unended, a hang `TODO.md` records under FD33's gaps.
* **The yield.** A receive from the thread itself whose timeout hit before it would wait yields the
  time slice (`thread-ipc.cpp`, [A yield](#scheduling)). Its test is the native task suite's
  `yield` case: upstream's receive keeps the CPU to the end of its slice, so the case misses its
  deadline.
* **The semaphore's wake.** A semaphore's down waits for the activation of the up that dequeued it
  (`semaphore.cpp`, [A semaphore's wake across CPUs](#thread-creation)). Its test is the case of
  that name in [The backend's cases](#the-backends-cases).
* **Test kernels' seeds.** Three defines, set only for a test kernel, compile seeds into the fork:
  `ERX_TEST_KERNEL_TRAP` a kernel-mode load from an unmapped address once boot is done
  (`kernel_thread.cpp`, for `native_kernel_trap.rb`), `ERX_TEST_SEMAPHORE_WAKE_HOLD_US` a hold
  of an up between its dequeue and its activation (`semaphore.cpp`, for
  `native_semaphore_race.rb`), and `ERX_TEST_KERNEL_WARN` a `WARN` at a task's yield, the second of
  which instead prints 8 KiB of warnings and then makes `ERX_TEST_KERNEL_TRAP`'s load (`thread-ipc.cpp`,
  for `native_console_ring.rb`). No other kernel builds them;
  `make check-native-seeds` runs all three.
* **The interrupt entry's stamp, development builds only.** At each interrupt entry the kernel writes one
  `irq_entry` record naming the line into its CPU's ring, so the Raspberry Pi 4's interrupt measurement times a
  receipt from Fiasco's interrupt entry ([Verification](#verification)). The record's layout, its coherence
  protocol, its pairing with receipts and its configuration option are
  [design-bench.md's contract](design-bench.md#the-interrupt-entrys-stamp). Only a development configuration admits
  the option: the release configuration's allowlist does not, so the release kernel carries neither the code nor the
  mapping.

Nothing else of erXos's kernel is built into Fiasco for the first release; the scheduler's stages
come after it.

**License.** With the clean-room header in the GPL original's place and `jdb_object.cpp` out, the
release kernel is Fiasco's MIT code, erXos's MIT clean-room header and erXos's BSD-2-Clause
additions. `bootstrap` and `sigma0` ship under the link closure their
import records (`fiasco/bootstrap/ORIGIN.md`, `fiasco/l4re-core/ORIGIN.md`), and a release build
check fails if any file compiled or linked into the image's kernel, `bootstrap` or `sigma0` is
recorded with a license that is not permissive; the check counts headers, since `kobject_rpc.h`
is one. Its seeded failures are two: a release build with `jdb_object.cpp` listed again in
`Modules.generic`, and one with the original `kobject_rpc.h` restored in place of the clean-room
header, so the headers case fails on its own; neither seed needs anyone to open either file. The mk
build links the toolchain's `libgcc` only under `CONFIG_COMPILER_RT_USE_TOOLCHAIN_LIBGCC`
(`fiasco/mk/mk/Makeconf:505-506`); erXos sets no such option, and the check confirms that no
`libgcc` is linked, since it is not among the allowed files. The compiler's freestanding headers
`stdarg.h`, `stdbool.h` and `stddef.h` come from clang's resource directory, Apache-2.0 WITH
LLVM-exception, a permissive license that the reviewed LLVM profile
(`config/provenance/llvm.json`) records and `FiascoProvenance.llvm_registry` adds to the build
record, so the check needs no exception: every linked source must be permissive. A release pins one
toolchain, LLVM 23.1.3 (clang and lld), for Fiasco and for everything else. Fiasco's notices go into `NOTICES` like every other
third-party component's ([design.md](design.md#licenses-and-notices)).

## Upstream security fixes

Fiasco stays erXos's code, changed by ordinary edits, but a release on it tracks upstream for
security: a review of Kernkonzept's `fiasco` repository since the imported commit, monthly,
decides for each commit that touches the kernel whether it fixes a defect reachable in erXos's configuration, and the
same review reads Arm's speculation advisories and upstream's AArch64 entry code for branch-predictor hardening, which
FD32 waits on. A
reachable fix is backported as an ordinary commit with a regression test where Fiasco's own commit
lacks one, and `fiasco/kernel/ORIGIN.md` records the last upstream commit reviewed. A Fiasco
defect found by erXos is fixed in the fork and reported to the address in
`fiasco/l4re-core/SECURITY.md`.

## Verification

Each increment is a QEMU transcript test under HVF, one and four CPUs, kept in the suite (TCG runs only the production image's deterministic transcript and one boot smoke at one CPU). A case has a seeded failure, a test-only patch that makes it fail, where it could otherwise pass vacuously, which shows the case
ran the code it claims to; `make check-native-seeds` keeps the suites' seeds and the test kernels of the semaphore race and the kernel trap. Exhaustive models are written for permanent cores only; a row of the call table is tested by a QEMU case for each call it offers, with AddressSanitizer on the host build, and TSan where it adds a lock. Host tests and TSan models run the pure cores. M7's parity gate runs the `erx` backend differentially against this one over the test corpus. Fuller recipes live with
the tests.

**One test set, two kernels.** The function-API set, `test/guest/function_api`, and Track K's
conformance suite run on both; each case whose answer differs from erXos's kernel's is a row of
[the call table](#the-call-table) that names its downside, and a difference no row names is a bug
in one backend.

**The system-call fuzz campaign.** A test domain on a release build invokes every slot index of its
object space, the empty ones included, with random operations, words and typed items, from many
threads at once, and checks after each run that the root and a neighbour domain answer and that no
memory outside the domain changed. Its corpus names every surface an app reaches as seeds of their
own, so none is left to chance: each protocol of each placed kind on its slot (an IRQ object's
trigger and unmask, and its bind and detach, which Fiasco refuses without the special right,
`irq.cpp:1104-1137`; a semaphore's up and down; a send and a call on the gate at
`L4_BASE_PAGER_CAP`, with every count of words and typed items the tag can hold); empty slots;
the open wait and the reply forms; and, through the special selector, which Fiasco resolves to the
calling thread with `CWS` whatever the slots hold (`thread_object.cpp:61-75`), every operation of
the self table of [Who holds what](#who-holds-what). The campaign reports how many inputs reached
each of those seeds, and a run in which one reached none fails. It runs on QEMU under HVF and TCG at a budget the milestone
gate sets; a crash or hang of Fiasco is a HIGH finding and its input joins the corpus.

### The backend's cases

Each case names its suite or host test, which holds its steps, and the seeded failures that show it
ran the code it claims to:

| Case | Seeded failures, and what each shows |
| --- | --- |
| **Image and banner**, `tools/erx check-boot-image`, `boot_image`: the banner image, the two-file form, each damaged entry refused with its reason | a damaged entry that boots |
| **Boot information**, host tests of `erx_boot_info_build` and `erx_boot_args_parse` at every limit, fuzz targets on the page's reader and the command line, the root's and the hosted entry's pages compared field by field | an unchecked `args_off`: AddressSanitizer; a word past the strings limit accepted; a wrong `pack_flags` in the root: the comparison fails |
| **The watchdog from the command line**, a test release under `erx.watchdog=1,5,600` stays up past `D` after its first pet | the first pet withheld under `1,5,7` and `1,5,14`: each ends with `ERX_CRASH_CAUSE_WATCHDOG` at its own `B`; `erx_watchdog` stopping after a pet: the end at `D`; a malformed `erx.watchdog=` and `1,5,2` (`B` under `D`) booting |
| **Native boot**, `native_boot`: the root accepts the record through `user_ptr`, checks the archive's last entry, writes one line and shuts down | shutdown removed: the deadline fires; `user_ptr` left 0: the root's accept refuses; the archive's sub-type removed: `sigma0` refuses the root's fault |
| **Debug log**, `tools/erx check-debug-log`, `debug_log`: the probe's calls compared record by record on both backends | one byte more than a full message (`make check-qemu-mutant`): only the target's transcript differs |
| **Kernel lines**, `native_console_ring`, a full boot under QEMU `virt` on a test kernel built with `ERX_TEST_KERNEL_WARN`, under which a receive from the thread itself with a zero timeout ([A yield](#scheduling)), a call every task can make, prints one `WARN` naming the test: a test program makes that receive once the console is up, the transcript must hold the warning as a kernel record, `#SEQ SECONDS.MICROSECONDS warning fiasco: ` and the escaped line, and its text nowhere else, and a line the harness types into the system shell while the warning is printed runs whole. A second such receive prints 8 KiB of warnings, twice the ring, and makes a kernel-mode load from an unmapped address. On a release test kernel the transcript must then hold `fiasco: N kernel lines lost` with N above 0, the trap dump's first line raw and the panic's `kernel trap` line raw; on a development test kernel, the loss line and the debugger's first output. The trigger is the test kernel's because the warnings a task causes on the stock kernel need conditions no test makes reliably, 64 parked faults for the reply-slot one, and the record's path does not depend on which line the kernel prints. `test/host/console_ring_test.rb`, over the core built for the host, holds the route machine to every route and operation, a take that hands out only whole lines, an overflow and an over-long line each taking the open line back and dropping its rest through the next newline, counted once, the same at a take that finds a line open on the UART, a close that finds a line open in the ring writing it out as the ring's last line, counting nothing, and ending any drop so that a stop's report written next reaches the UART whole, a take after the close handing out nothing, the close's rendering of a line holding ESC and NUL as `fiasco: ` and its escaped bytes, and the reader's carriage returns and empty lines; the log core's host test logs `a`, NUL, `b` through `erx_log_bytes` as `fiasco: a\x00b`. QEMU's UART models are not known to lose input as the hardware does (unverified), so the loss itself is an item of the Raspberry Pi 4's manual checklist: a 4 KiB paste into the system shell while a program triggers the warning in a loop arrives with no loss | the take's kernel operation never called: the warning reaches the UART raw and the case fails; the close at `Trap_state::dump` removed on the release test kernel: the dump's line is missing while the panic's line, which only `panic`'s own close lets out, is still there, so the run proves both closes; the close at the development kernel's `Jdb::open_debug_console` removed: the debugger's output never reaches the transcript; the open line not taken back at an overflow: a prefix joins the next line and the framing test fails; the drop not ended at the newline: the next whole line is lost and the test fails; `erx_log_bytes` replaced by `%.*s`: the record reads `fiasco: a` and the test fails; on the Pi 4's checklist, the take's operation never called: the paste loses bytes |
| **Memory**, `native_memory`: commit, decommit, protection changes and the whole pool keep contents and count | the wrong window page; zeroing skipped; a protect that takes a fresh page; the pool check removed: a protect that should be refused is not |
| **Protection**, a test task: a write in RX and a run in RW fault; a stack through `PROT_NONE`; a refused protect changes nothing | the drop step skipped: the write succeeds; commit on access change removed: a fault; the plan applied page by page: the first page changed |
| **musl**, `native_musl`: the C library's interface as the root, threads, TLS, condition variables, timed waits, `malloc` across threads, `mprotect` under a running thread, cancellation, `exit` | `FUTEX_REQUEUE` restored: a broadcast stalls; `__unmapself` not releasing: the pool's count stays down; `mprotect` committing first: the running thread faults |
| **Range table**, `fiasco_vm_test.rb`, exhaustive over page states, ranges and calls against a fake memory unit that adds rights as Fiasco does | write and execute admitted together; a page given back still mapped; each memory seed of this table |
| **Thread start and failed start**, `native_threads` and a test-hook image: TLS equals the value given; a start failing at each step leaves no capability and an untouched stack | the trampoline omitting the thread pointer; the deletion skipped: the capability stays valid |
| **Claim**, `fiasco_park_test.rb`, a fake kernel writing the marker late over every order of exit and create | the claim ignoring the marker: the fake's write lands on a live thread |
| **Umtx**, host model and TSan: a timed wait never early, a wake between compare and sleep, a timeout racing a wake | the deadline rounded down; the compare outside the lock: a lost wake; absorb removed: a stale count |
| **Join and detached loops**, `native_threads`: 10,000 joins reuse stack and index and leave no capability; detached exits return range, index and pool; a broadcast over 64 waiters | the reaper's steps 1 and 3 swapped: a live capability; step 3 removed: the case times out; the range omitted: the count falls; the next waiter's barrier left locked: the deadline fires |
| **Park**, `fiasco_park_test.rb` exhaustive and under TSan; on QEMU, a trigger between the empty check and the park, two executors on two CPUs, a timeout racing a wake | the epoch comparison removed: a lost wake, on the host and on QEMU; an up to a slot not listed: a stale count |
| **Group report**, `group_report_test.rb`: the executor count and the report line at zero and the largest counts, in a buffer of exactly its size and one a byte short | an empty slot counted or the last skipped: a wrong count; no room kept for the NUL: a write past the buffer; a count one digit short: a wrong line |
| **Kernel reports**, `function_api`'s `object_info` cases and the production image's summary of `erx_kernel_records`: each topic's `reported` bits as [Reporting kernel objects](#reporting-kernel-objects) lists them, partial fields named, nothing fabricated | the pool's count skipped on a commit: `used` does not move; a clear field's bit set; a failed `l4_scheduler_info` leaving `cpus_online` set; `used`'s bit set for a partial field; the summary's mutants, one status off each (`production_image_test.rb`); `erx_info_report`'s machine branch mutants (`object_info_test.rb`) |
| **Affinity**, `native_threads`: a thread pinned to each CPU in turn stops only that CPU's probe | the mask ignored |
| **A second task**, `native_task`: a JIT object's two aliases across CPUs; a write in the read-execute alias and a run in the read-write alias each end the task alone; an IRQ object, a physical object over registers and a contiguous run made from a task are `ERX_ENOTSUP`, and its use of a handle it does not hold, the root's own object among them, is refused | the read-write alias mapped read-execute; the create refusal removed (`irq_refused`); the handle looked up in the root's table; the root check of physical and contiguous creates removed (`device_refused`) |
| **`libc-test` canary**, `native_libc_canary`, about ten programs as tasks; no boot leaks the pool | a test that does not pass or is not run: `canary_problems` refuses the totals |
| **Task exit and requests against it**, `native_task`: with a thread spinning on each CPU, every capability of the task gone and the pool returned; a request racing exit 1,000 times drops nothing | thread deletion skipped: a capability stays valid; the memory step skipped: the pool is short |
| **A task's write**, `native_task`: a test task's bytes reach the serial log unchanged; a raw `task_write` from a domain or a session's program is `ERX_ENOTSUP` and writes nothing, and its `test_space_create` `ERX_ENOTSUP`; `erx_debug_log` escapes and refuses as its row says | the write sent through `erx_debug_log`: the bytes are missing; the test-task mark not checked: the domain's escape sequence reaches the serial log; the root check of `test_space_create` removed: the task's create succeeds |
| **A payload read once**, a host test of the decoder over a public UTCB a second thread rewrites | the length read again from the public UTCB: AddressSanitizer reports the overread |
| **Task fault**: the record appears and the machine continues | the fault ending the machine |
| **Interrupt**, `native_irq` and `fiasco_time_test.rb`: a UART line and a software object wake a parked executor across CPUs through the root's dispatcher; ack opens the line; a holder binds and acks its own line and is refused the root's group | ack removed; the listed flag ignored: a label reported twice; the interlock removed: the early trigger lost; the dispatcher's trigger removed; the hooked trigger removed; the home check of a task's bind removed |
| **Trace ring**, `trace_ring_test.rb` and TSan: lapping, overwrite during a read, bounds, a task's call `ERX_ENOTSUP` | the second `seq` load removed; the head start returning 0; the skip counted one short; the cursor check removed: stale slots copied; the `max` bound removed; a read that ignores `max`: a copy past its slot; the terminal check removed; the exhausted head's check removed; the odd store removed; the ring linked into a task in place of the stub: the link lists' test fails |
| **Trace on four CPUs**, `native_trace`: the kernel row's `unsupported` line, a backend `park` and `wake`, the workload's `in` not `late` | the park core's `trace` effect removed; the clock offset's sign flipped; `erx_trace_read` answering `ERX_OK` with no records: the `unsupported` line is missing |
| **Watchdog**, `native_watchdog`: pets hold the machine up; once they stop a spinning thread does not keep it from ending and resetting | the end skipped; pets ignored |
| **A backend lock across CPUs**, `native_lock`, on four CPUs: two threads of a task on two CPUs each take and release one backend lock 100,000 times and add to a counter that only the lock guards, and a thread at the ceiling contends on the first one's CPU for the last tenth; the counter ends at 200,000, and with the lock free and no thread waiting a down on the lock's semaphore with a zero timeout times out, so no credit is left; a pause of the task while one thread waits on the lock, and its resume, leave both results unchanged | the unlock's up made when the word was 1 or more: a second holder, so the counter falls short, and the zero-timeout down succeeds; the down after a cancel not retried: the waiter goes on without the lock and the counter falls short |
| **A semaphore's wake across CPUs**, `native_semaphore_race.rb` under `make check-native-seeds`, on a test kernel that holds the up between dequeue and activation | the bit's wait removed: the IPC wait ends early |
| **A kernel trap on a release kernel**, `native_kernel_trap.rb` under `make check-native-seeds`: one `Panic: kernel trap` line, then PSCI's reset | the handler that kills the faulting thread and returns, as Fiasco's release build does: trap dumps repeat |
| **End path**, `native_crash`: each fault's whole crash frame; a root fault's undrained lines; `erx_machine_end` with each `how` | the frame's write removed; the drain removed |
| **Console handoff**, `dispatch_test.rb` and the console suite: each line once and in order across the take; a tab and an escape sequence logged after the take arrive escaped | the sink never switched: the service's write counter moves |
| **Manifest check** | each kept property's seeded violation and each refusal's seeded record ([the table](#the-phase-1-manifest-check)) |
| **Service decoder**: a fuzz target, and a task sending an unknown number, a wrong count, a bad index, a long payload | the word-count check removed |
| **Chokepoints**: a Fiasco header outside the backend; `fiasco-charge` | the violation itself: an `l4_task_map`, an `l4_factory_create_irq` and an `l4_task_add_ku_mem` in `service.c` each fail the build |
| **Production image**, `production_image`: device paths and windows against QEMU's tree; boots with the watchdog's numbers and exact argument count; refusals of an unknown `erx.` word and a small machine; the serial console; the TCG smoke boot with no host link | a wrong path, compatible or window; a console driver dropping input or output; a misread `root_memory` or a lost `-append`; a host link record handed without the word: eight more arguments and a root fault |
| **The manifest's C reader**, `manifest_fuzz.c`: each table read back to its count | a row out of a table's range aborts it |
| `make check-reproducible`: two builds byte-identical | a time or a build path reaching an output |
| **Function-API set** on each backend that carries a case's row, refusals included | a refusal changed in one backend |
| **Mapping between tasks**, `native_space` and `fiasco_vm_test.rb`: the writer's bytes reach the reader; the pool returns only after the last release; maps over committed pages refused | the mapping list's decrement removed; the overlap check removed |
| **Revoke**, `native_space`: the creator's destroy faults every holder's next read; another task's destroy is `ERX_ERIGHTS` | the revoke step removed |
| **A stale handle**, `function_api`: after a destroy, a doorbell's trigger and a service call on its handle both answer `ERX_ESTALE` while the holder keeps the entry; after a close, a service call on the old value answers `ERX_ESTALE` once the entry is taken again by an object of the same kind | the root freeing the holder's entry at the destroy; the close not advancing the entry's generation, under which the old value names the new object |
| **The tree**, `native_space`: a child's exit record, `ERX_EXIT_PARENT`, before its parent's | children walked after their parent |
| **Passing**, `native_space`: copies and moves within the mask less `DESTROY`, `ERX_ELIMIT` past room, a gate's handle `ERX_ENOTSUP` | none of its own: the holder's map fails if a copy does not raise the count |
| **A session's install**, `native_space`: a parent binds into its child's group before the child runs, installs a budget, a group, both channel sides and a doorbell, and starts it with the values in `program_arg`'s registers; the child is refused a bind into a group it neither created nor is home of, and the parent a pass into its own space | the creator's bind refused; a bind into any group allowed; a pass into the caller's own space allowed; the trampoline loading fewer than eight registers |
| **Fault gates**, `native_space` and `fiasco_gate_test.rb`: a fault record, then the exit record; a wait with nothing posted times out | the owed down removed; the record posted before the deletions |
| **Doorbells between tasks**, `native_space`: a bind before the task's first thread; a cross-task thread `ERX_ENOTSUP`; an object left unbound at its home's exit | the deferred bind dropped; the home check removed; the detach at task exit removed |
| **A budget's destroy**, `function_api` and `native_space`: one destroy ends everything charged to a budget and its carved budgets | the walk skipping carved budgets |
| **Code objects**, `native_space`: a paged object maps nowhere unsealed, refuses a supply and a writable map once sealed; `ERX_MEM_CODE` from a task `ERX_ERIGHTS` | the sealed flag not read at the map |
| **Copy and slices**, `native_space`: a copy `ERX_ESTALE` once the source is destroyed; a slice's write faults | the destroyed check removed: the copy reads freed pages; a slice mapped with write: the write lands in the archive |
| **Shared image segments**, `native_space`: one image entry in six tasks, each with its own writable segment and read-only code | the image slice charged to the space's budget; code mapped writable; the writable segment shared |
| **A task's start, time and release**, `native_space`: the wall clock, a release slice's entries and offsets, a memory handle refused as a thread | `erx_time_page` returning the root's address; offsets from the archive's start; the stub taking one piece; the base check removed: the start takes the memory handle for the thread |
| **Devices in domains**, the production image suite: each transport's magic and device id through the objects given | a platform record naming another device's transport |
| **Bounds**, `function_api` and `native_space`: `erx_vm_map`, `erx_mem_copy` and `erx_mem_supply` past the object and at a wrapping offset `ERX_ERANGE` | the end check written without checked arithmetic: the wrapping offset reaches another object's page |
| **Entry reuse**, `function_api` and `test/host/handles_test.rb`: never-used entries are taken in index order, then the entry freed first is taken first; an entry at its last generation retires | free entries taken newest first; a retired entry taken again |
| **A group and its threads**, `native_space`: a live group's destroy `ERX_ENOTSUP`; its budget's destroy stops its home task | the refusal removed: the pool stays short by the thread's stack |
| **Holders restarted**, `device_give` and the production image suite: a configured holder and the network domain each restarted get new window and line objects and the same memory | the restart's plan with no gives; the line's object not deleted at the exit record: the give is `ERX_EBUSY` |
| **vCPU upcalls**, `native_signal`, at 1 and 4 CPUs: a worker interrupted on another CPU, a signal raised during a kernel call run at its return, FP registers restored | a queued delivery ignored at resume; the pending-flag test dropped; the backend entry copying with a SIMD instruction |

### The release's cases

Each test below names the seeded failure that proves it ran:

| Test | Passes when | Seeded failure it must catch |
| --- | --- | --- |
| destroyed handle | after a peer's destroy, a holder's trigger and its service call both answer `ERX_ESTALE` | the root frees the holder's entry at the destroy and places a new doorbell at its IRQ slot |
| a creator's pass | the domain library passes a device line to its holder with a mask holding `BIND`, and the holder binds it to its own group; a second line passed to the same holder with a mask without `BIND` makes the holder's bind of it answer `ERX_ERIGHTS` | the pass intersecting with the type's pass set: the first holder's bind answers `ERX_ERIGHTS`; the mask ignored at the pass: the second line's bind succeeds |
| trigger-only doorbell | a ringer's bind of a peer's doorbell answers `ERX_ERIGHTS` | the root places the ringer's capability with Fiasco's special right |
| rights shrink | a duplicate with a narrower mask cannot do what the mask removed, directly or by a service call | the root maps the source's Fiasco rights unmasked |
| delete revokes everywhere | three holders' uses fail after one destroy | the destroy unmaps the root's own slot instead of deleting |
| memory wall | a domain allocating past its budget gets `ERX_ENOMEM` while a neighbour still allocates | the root's page charge skips the cap |
| kernel-memory wall | a domain making doorbells, memory objects and mappings until its factory is spent, and then until its object and mapping limits, gets `ERX_ENOMEM` and then `ERX_ELIMIT`, and the root and a neighbour still create and map objects | the root creates from its own factory; the object limit not checked, so the domain fills the root's tables and the neighbour's create fails |
| no task capability | a probe of every slot of a domain finds no task, factory, thread or scheduler | a placement of the domain's own task capability, kept as a build that must fail |
| direct doorbell | a ring and its wake make no request to the root (the root's request count is unchanged) | the trigger stub sends a request |
| band | a fixed piece of a configured domain's ordinary work takes no longer, within a tenth, while an app-band domain spins every thread on its CPU | the spinning domain placed at the base level: the work takes its turns among the spinner's threads and several times as long |
| quantum | two threads of a task the root launched, alone on one CPU, take turns whose median of 15 lies within 250..4000 us around the root's 1000 us slice | the root giving a thread the slice of its task's own row, which holds none, in place of its domain row's: the threads take Fiasco's 10 ms default |
| base sharing | the `system_domain` suite's load on one CPU, `LOADERS` processes calling each party without pause: the system domain's own facet, the session's and that of a peer whose limits record names `interactive` each answer within `LOAD_MS` | the root band's base one priority above the base level: the session and the peer answer nothing |
| urgent thread | at one CPU and at four, a thread of a driver-band task that set its urgency above its group's base finishes a fixed piece of work in the same time, within a tenth, while a base-level thread of another task on its CPU is woken every 100 us | the service's body answering without its `l4_scheduler_run_thread`: the wakes preempt the thread and the work takes longer |
| urgency ceiling | a thread of an app-band task and one of an interactive-band task each call `erx_thread_set_urgency` with `ERX_URGENCY_MAX`: a base-level thread's fixed piece of work beside each takes no longer | the root's table giving every band the urgent level as its ceiling: the app thread runs above the base and the work waits |
| line to a thread | in a driver-band task, a worker at the ceiling waits in `erx_ipc_wait` for a doorbell of its own task bound to it, while base-level threads of the task and of a neighbour task on its CPU spin and one of them is woken every 100 us; a base-level thread fires the doorbell 1,000 times, and after each receipt the worker does 200 us of work: every receipt returns the label the bind gave, and from each fire to the end of its work no more than 400 us pass | the worker's `erx_thread_set_urgency` dropped: the wakes and the spinners' turns interrupt its work and receipts pass a quantum; the bind made to the task's group: the worker's wait ends only at its deadline |
| thread-bound doorbell | a driver-band task's bind to its own thread of a doorbell it passed to a space it created answers `ERX_ENOTSUP`, and so does its pass of a doorbell bound to its thread; in an app-band task both succeed, and its thread stays at the app level | the bind's holder check removed: the bind of the passed doorbell answers `ERX_OK` |
| urgency kept across a move | a thread at the ceiling of a driver-band task moved by `erx_thread_set_affinity` to another CPU of its set finishes a fixed piece of work there in the same time, within a tenth, while a base-level thread on the new CPU is woken every 100 us | the affinity body passing the band's base in place of the thread's recorded level: after the move the wakes preempt the thread and the work takes longer |
| donated call | a thread at the ceiling of a driver-band task, on the root service's CPU, makes 10,000 `erx_object_info` calls while a base-level thread there is woken every 100 us, in no longer, within a tenth, than with no wakes | the stub's tag given the `Schedule` flag: each body runs on the service's own context at the base level, the wakes preempt it, and the calls take longer |
| blocking lock | a base-level thread takes a backend lock and wakes a thread of its task that runs at the ceiling on the same CPU and takes the same lock: both finish | the waiter spinning on the word in place of its down: the holder never runs again and the case's deadline ends it |
| pinned schedulers | a runtime whose CPU set has four CPUs runs one normal and one dirty CPU scheduler on each, by the one-CPU masks the root holds for its executors | the adapter's pin removed: all report the root service's CPU |
| urgent scheduler | in a driver-band test domain on one CPU, every normal scheduler runs a `normal` process that loops without a wait and allocates, so that it collects garbage, and a neighbour domain spins at the base on the same CPU; a line the domain holds fires 1,000 times, and a `high` process takes each event and does 200 us of work: from each fire to the end of its work no more than 500 us pass; the `high` process reports the urgent scheduler's id, and a `normal` process it spawned one of the normal schedulers' | the enqueue's rule for `high` removed: the process runs on a normal scheduler, behind the loop's slice of reductions and the neighbour's turns, and receipts pass 1 ms; its rule for `normal` removed: the spawned process reports the urgent scheduler's id |
| line behind urgent work | in the urgent scheduler case's domain, a second `high` process runs 50 ms of reductions without a wait while the line fires 1,000 times: from each fire to the end of the driver's 200 us of work no more than 2 ms pass | the safe-point wait removed, so the urgent scheduler takes a delivery only when its queue is empty: receipts wait for the loop's end, up to 50 ms |
| a block | in a driver-band test domain, after `erlang:system_flag(multi_scheduling, block)` returns `blocked`, a `high` process and a `normal` one each report scheduler 1, a line fired 100 times during the block reaches its `high` process each time before the unblock, and after `unblock` the `high` process reports the urgent scheduler's id again; `process_flag(scheduler, N)` with the urgent scheduler's number is `badarg`, and a `high` process bound to scheduler 1 reports scheduler 1 | the urgent queue left out of the block's suspension: the `high` process reports the urgent scheduler's id during the block; the suspended urgent scheduler waiting on its thread event: no line's message arrives before the unblock; the bound check made after the priority rule: the bound process reports the urgent scheduler's id |
| an MSI to the urgent scheduler | on QEMU `virt`, a driver-band test domain whose image gives it the MSI frame's page binds an MSI to its urgent scheduler, and a base-level thread of it writes the MSI's data to the frame's doorbell 10,000 times while the `high` process that takes the line never calls `erx_irq_ack`: the process receives more than one delivery and no more than the writes, the count reported with the run, and the domain's ordinary work on its other CPUs goes on; that a store by a CPU raises the frame's line as a device's write does is unverified, and if it does not, the case runs with a virtio PCI device's MSI | the MSI bound to the task's group: the urgent scheduler counts no delivery |
| urgent roster | in each runtime that has an urgent scheduler, through the release's boot to the shell and then under its client load, a session writing to the console without pause, another domain logging without pause and a module loaded and purged in the system domain, every process traced running on the urgent scheduler (`erlang:trace` with `running` and `scheduler_id`) is one the runtime's roster names, and the urgent scheduler is busy for less than a twentieth of the run | a process started at `high` during the system domain's boot and left off the roster: the case names it; the enqueue's rule reading the priority a process is enqueued at in place of its own: the purge's checks of process code run on the urgent scheduler and the case names their processes |
| sub-space band | a session's program spinning every thread delays its own session's echo, in the interactive band, by no more than one quantum | the root gives a new space its creator's own band: the program runs in the interactive band and the echo waits out the spin |
| app session band | an app whose session's template names `interactive` spins every thread and delays an interactive domain's echo by no more than one quantum | `erx_dom_plan_app_session` keeps the template's band: the app runs beside the echo |
| root-only domain form | a domain's `domain_space_create` answers `ERX_ENOTSUP` and makes no task: the domain's object count is unchanged | the root-only check dropped: the domain's request makes a task |
| thread limit | a create past the domain's limit answers `ERX_ELIMIT` | the count skips a sub-space's threads |
| whole-space pause | a paused space's write counter stops advancing until the resume, with one thread parked on its semaphore, one in a umtx wait and one faulted and held; a space with a thread that repointed its exception handler ends at the deadline and the requester gets `ERX_EDEAD`; the root serves another domain's request while the pause is pending | the root skips the last thread it created; `Exr_cancel` dropped: the parked thread never arrives and the deadline ends the space; the root waiting for the arrivals: the other domain's request is not answered before the deadline |
| the wall clock | a task's `erx_time_set_offset` on the time page's handle without `WRITE` answers `ERX_ERIGHTS`, and the page's offset is unchanged | the body's right check removed: the offset moves |
| FP state | two threads of different spaces holding distinct vector registers keep them across switches and a migration between CPUs, and a fresh thread reads its vector registers as zero | the switch's restore skipped: the second thread reads the first's registers |
| DMA confinement | a device's access outside its window is refused and reported | the whole pool mapped into the DMA space |
| writable or executable | a request for such a mapping into a task fails at Fiasco's map, and the root still boots from `sigma0`'s mapping | the patch's check removed: the mapping is made; the exemption removed: the root does not start |
| release licenses | the release image's link closure is all permissive | a release build with `jdb_object.cpp` listed again in `Modules.generic`; one with the original `kobject_rpc.h` restored in place |
| the fuzz campaign | it runs its budget clean, every seed of its corpus reached | a fork build with the bound removed from `L4_snd_item_iter::next` (`if (_buf >= _max)`, `l4_buf_iter.cpp:116-121`), which any domain reaches by a send on its own gate whose words and typed items together pass the 63 message registers (`Utcb::Max_words`, `abi/l4_types.cpp:789`), so the kernel's item transfer writes past the root service's message registers before the root's decoder sees the message (`Thread::transfer_msg_items`, `thread-ipc.cpp:1203-1227`); the seed build counts each pass of the removed bound, the case fails if that count is 0, so it cannot pass without reaching the defect, and it fails if the campaign then reports clean |
| a map at the factory's end | a domain whose page budget exceeds its kernel-memory figure spends its factory before its page cap or its object and mapping limits. It has closed no handle, so the root hands it never-used entries in index order before any freed one ([Handles](#handles)). While its factory is ample, it makes doorbells until the IRQ slot of the handle it gets is the last slot of a capability-table page, keeping that one, `D`, so the next IRQ slot the root places at is the first of a page Fiasco has not allocated; it commits a page and sets it to no access; it then commits a page in each fresh 2 MiB region, each taking a page-table page, until one answers `ERX_ENOMEM`, and there asks for the commit, the protect and the arming named below; it then commits single pages in regions already mapped until one answers `ERX_ENOMEM`, so its factory holds less than one mapping-database node's charge. Last it destroys and closes `D`, then asks for the create: the root's delete returns once Fiasco has freed it, its slab entry back in the factory, and its entry goes behind the never-used ones, so the factory holds enough for an IRQ object's slab entry but not for a new table page. A two-page commit across a fresh region's edge, a protect of a no-access page, an `erx_vcpu_control` arming a thread (which needs the task's second kernel-user area) and an `erx_irq_create` (whose placement needs the new table page) each answer `ERX_ENOMEM`; a touch of each refused range faults in the domain alone, the arming leaves the thread unarmed, the pool's count and the domain's object count are what they were before each call, and a neighbour domain keeps committing. The recipe rests on Fiasco's sizes (a 4 KiB capability-table page, `obj_space_phys_util.cpp:221-226`; its 32-byte entries, `obj_space_types.cpp:45-102`, read, not measured; an IRQ object's slab entry, `irq.cpp:1201-1206`; a node's charge, `mapdb.cpp:858`; deletion past an RCU grace period, `kobject.cpp:155-175`) | a refused map ending the machine; the commit's undo skipped (the pool's count drops and the refused commit's first page reads); the undo returning every page of the plan to the pool (the refused protect raises the pool's count); the add's refusal ignored (the arming answers other than `ERX_ENOMEM`); the create's undo skipped (the object count rises with no handle returned) |
| writable peer side | a domain sends a raw `erx_vm_map` request asking for read and write on its peer's side, which it was passed without `WRITE`: `ERX_ERIGHTS`, and after the domain writes through every mapping it holds, the peer's side is unchanged | the map body not asking the lookup for `WRITE`: the mapping is made and the peer's side changes |
| CPU ceiling | a domain whose CPU set is one CPU, not the root service's, starts its threads with no mask, moves one by a raw affinity request naming every CPU, and spins them all, while a lower band's echo runs on the root service's CPU: the echo answers within one quantum, and a raw request naming only CPUs outside the set answers `ERX_EINVAL`; a domain whose set names only a CPU past the online ones is refused at admission with its diagnostic | the narrowing skipped: a spinner lands on the echo's CPU and the echo waits; the admission check removed: the domain is admitted and its first thread's start fails |
| repeated delivery | a ringer on another CPU fires a holder's doorbell 10,000 times while the holder's executors postpone `erx_group_take_ready`: the holder's next take returns the object once, and its dispatcher's deliveries and wakes are counted and reported with the run, the load FD31 publishes | the listed flag ignored: the take returns the object more than once |
| doorbell flood | on four CPUs, an app-band domain's threads on three of them fire doorbells of a system-domain group as fast as they can while a fixed piece of the system domain's ordinary work runs on the CPU of the root's dispatcher: the work finishes within ten times its unloaded time, and the dispatcher's deliveries are counted and reported | the root's dispatcher started at its band's ceiling: the urgent level stays busy and the work does not finish before the case's deadline |
| release entropy | a release image booted on QEMU `virt` with no `/chosen` seeds (QEMU's `dtb-randomness=off` machine option, which the harness already passes for deterministic runs, `tools/lib/erx/qemu.rb:39`) prints the refusal line and ends before any domain starts; the Raspberry Pi 4's manual checklist does the same with the RNG200's read made to fail | the refusal skipped: the boot goes on and a domain starts |
| trial | on QEMU `virt`, an update's `ERX_END_TRIAL` ends with `erx: end trial`, the harness boots the spare slot once, and the committed slot boots after a trial that does not commit; with the boot value `unknown`, `ERX_END_TRIAL` answers `ERX_ENOTSUP` and the machine runs on | trial mapped to a reset: the last line is `erx: end reset` and the harness boots the committed slot; the boot-value check removed: the machine ends |

**The Raspberry Pi 4's interrupt measurement.** The board is measured by hand, on its development
image, and its records go to the history repository. It has six
cells, each run for the console's line and for the SD controller's:

| Cell | Load while it runs |
| --- | --- |
| idle | none |
| system load | in the system domain, one process of priority `normal` for each of its CPUs, looping without a wait and allocating, so that it collects garbage |
| neighbour load | the system load, and the same loop in root's session, whose CPU set is the system domain's first CPU |
| wake load | the system load, and in root's session, whose CPU set is the console driver's CPU, four processes each sleeping 400 us and then working 50 us, so the session's executor there wakes about every 100 us |
| output load | the system load, and in root's session a process writing lines to the console without pause |
| service load | the system load, and an app-band task sending the root service requests without pause |

In each cell the host pastes 100 lines of 41 bytes into the console at 115200 baud, and a reader
in the session reads 64 MiB from the SD card. A cell passes when the console driver reports no
receive FIFO overrun and the line editor refuses no line, when no receipt of the console's line,
timed from Fiasco's interrupt entry to the driver's process by the interrupt probe's stamps, takes
over 0.7 ms, and when no receipt of the SD line takes over 1 ms, of at least 50. Each cell's
record holds its longest receipt of each line, which is where a wait for a lock held at the base
or for a request to the root would show ([Urgency](#urgency), "What it bounds, and what it does
not"). With the urgent scheduler built, the output-load cell also records how long it was busy,
which must stay under a twentieth of the cell, since the console's output reaches the urgent level
([Urgency](#urgency), "What reaches the urgent level"). The service-load cell is reported and
neither passes nor fails: it prices FD17's delay of urgent work.

The measurement runs twice. Before urgency is built, on the levels, the pinned schedulers, the
1 ms slice and the parks alone, the idle, system-load, neighbour-load and output-load cells pass
or fail as above, the service-load cell is reported, and the wake-load cell is reported too: its wakes keep putting the session's executor in front of every thread that is awake
at the base, a wait nothing bounds there, so it records, from the trace ring's park and wake
records, whether each console receipt was taken by an executor its trigger woke or by one that was
already awake, with the receipt's delay and the FIFO overruns. A byte lost in a loaded
cell is what has urgency built ([Open decisions](#open-decisions)). With the urgent scheduler built, every cell but the service-load cell passes or fails, and the
wake-load cell is the one that confirms it: the driver's process no longer waits for the base
level at all. The seeded failures, each run once on the board:

| Seeded failure | What must fail |
| --- | --- |
| the enqueue's rule for `high` removed, so the driver's process runs on a normal scheduler | console receipts over 0.7 ms, and lost bytes, in the wake-load cell |
| the console's line bound to the group, so its delivery passes through the dispatcher at the base | console receipts over 0.7 ms in the wake-load cell |
| the system domain's runtime started with `+sbwt very_short` | SD receipts over 1 ms in the idle cell, as the probe's image F shows 7 of 53 |
| the adapter's pin removed | console lags over 0.7 ms in the system-load cell, as the probe's images C and E show |

A cell that passes with its seed in place proves nothing about the mechanism the seed removes, and
is reported so.

## The hosted backend

`liberx/backend/hosted/` gives, in a macOS process, the call table's rows that one process carries cheaply, for the sanitizers and `lldb`. `liberx/backend/api.h` declares the function API both backends implement, and `liberx/backend/core/` holds what they share: the park core, the range table and the calls both refuse, so the same refusals and the same park protocol come from one source. A space is the process, a thread is a pthread, a memory object's pages are one `mmap`ped area, a umtx wait is `os_sync_wait_on_address`, and an IRQ object fires in the caller's thread, with no dispatcher. `test/guest/function_api` is the one test set: its cases read no backend's identifier, and its harnesses, `hosted.c` and `guest.c`, give it a place to print.

These differ from the native backend, and a caller must not depend on either side:

* **A pthread can be an executor.** `erx_pthread_create_executor` claims a thread record and a slot in the creator, so no free slot is its `EAGAIN`, and a start wrapper's cleanup handler gives both back at a return, a `pthread_exit` or an `erx_thread_exit`. The body natively is musl's.
* **The group's report is an environment word.** With `ERX_HOSTED_GROUP_REPORT` set, a thread looks at the status page ten times a second and the console gets `erx: hosted: group: parked N of M` each time the count of parked executors or of executors changes, so a test outside the process can read an idle sample. Natively the same report is the kernel command line's `erx.group_report=1` ([The command line](#the-command-line)).
* **The host's page is larger.** Apple Silicon's page is 16 KiB and the ABI's is 4 KiB. A host page's protection is the union of its pages', so a touch that must fault natively may succeed hosted when a neighbour in the same host page allows it, and a stray write to an uncommitted page beside a committed one survives its commit. A call's pages change together when it is whole, and a reserve without `ERX_VM_FIXED` starts on a host page, so unrelated ranges share none. A writable and an executable page that end one call in one host page cannot be represented, and end the process with a diagnostic. A decommitted page's bytes stay readable while a neighbour keeps its host page, and are cleaned before the page is next taken, under a brief write right on the whole host page, during which a neighbour's code cannot run.
* **The pool is a count**, of 8 GiB, which OTP's own suites need part of, over a 64 GiB area. Nothing is touched until written, except the range table's index, which its start clears: 64 MiB.
* **A report of runs.** With `ERX_HOSTED_VM_RUNS` set, the console gets a line each time a call changes the count of the range table's runs or of committed pages: the count, its high mark, the limit and the committed pages. `make check-runtime-hosted` prints it at `1>`.
* **A thread's stack switches at its start.** The pthread starts on its own stack and moves to the one the start record names, and back to end, in the host architecture's `arch/<arch>/switch_stack.S` (each file assembles to nothing for another target), and `thread.c` tells the address sanitizer of each move. The thread pointer is a field read through `erx_thread_pointer`, since the host owns the register. The first thread is a worker with no thread pointer, and its `erx_thread_exit_release` releases nothing.
* **Affinity is checked, not applied.** macOS cannot hold a thread to a CPU.
* **The wake order is the host's.** Natively the oldest waiter wakes first; `os_sync_wake_by_address_any` promises no order, so that case stays with the native guest. A wake's count is of the host's wakes, so a waiter that waits again at once on the same word may count twice.
* **No devices.** A well-formed `erx_mem_create_physical` or `erx_mem_create_contiguous` is `ERX_ENOTSUP`, since a device's address here would be made up, and `erx_mem_dma_addr` and `erx_vm_map` are `ERX_ESTALE`, since no handle names such an object. `erx_device:open/1` reports that refusal for a real window. Its `stand_in` window, in a hosted build alone, is plain memory with software objects for lines: a `virtio_mmio` stand-in plays a version 2 transport and its device writing the used ring, honest or hostile, and a `genet` stand-in plays a GENET v5 and its PHY; `erx_device:stand_in_fire/2`, `stand_in_used/3` (an index ahead of what is in flight, a foreign head, an over-length entry), `stand_in_transmitted/1` and `stand_in_receive/2` play the device's side, each reading descriptors and buffers through the window as the controller does, never through the NIF's bookkeeping. Both backends refuse a malformed request from one source, `liberx/backend/core/device_check.h`. Entropy is the host's `getentropy`, and an add takes nothing; with `ERX_HOSTED_ENTROPY_FAIL=N` the first N reads go through and every later one is `ERX_ENOTSUP`, the failure the native backend gives when it cannot reach its generator service.
* **No lines.** `ERX_IRQ_LINE` and `ERX_IRQ_MSI` are `ERX_ENOTSUP` hosted; natively the root makes both, an MSI as a line of the platform's MSI frame ([The call table](#the-call-table)). A trigger of an object not bound delivers nothing, and a bind takes any nonzero group, since there is one.
* **An object fires in the caller's thread.** A trigger has listed its object and advanced the epoch by the time it returns, each fire counted, and a bound object rebinds under a new label or unbinds. Natively a trigger reaches the dispatcher later, the kernel keeps two fires not yet received as one, and a second bind, an unbind and a rebind are `ERX_ENOTSUP`; a caller must wait on the epoch, as an executor does. So `irq_ready_once` and `irq_line_refused` run hosted only, and the rest of the IRQ row on both.
* **A reset is exit status 75**, an end `exit(0)`.
* **A fault is the host's**: the process ends with the host's signal, under `lldb` or a sanitizer, and writes no crash record.
* **A runtime links libSystem.** ERTS's threads are libSystem's pthreads with libSystem's TLS, and `erx_utcb_self` is a thread-local block (`hosted/log.c:40`), so it works on any host thread. Only a thread that `erx_thread_create` or `erx_pthread_create_executor` made has a slot; for one that plain `pthread_create` made, `erx_executor_slot` says none and `erx_park` is `ERX_ETYPE`, as for a worker natively.
* **Time.** `erx_clock_ns` is the host's `CLOCK_UPTIME_RAW`, the raw counter that stock OTP also takes on macOS and that the hosted wait's `OS_CLOCK_MACH_ABSOLUTE_TIME` counts in: nanoseconds, stopped during a sleep of the machine, and never below a thread's earlier read, which ERTS's time supervisor checks on every read and stops the runtime over. `CLOCK_MONOTONIC` does not keep that promise on macOS, since it is the wall clock less the boot time. `erx_time_wall_ns` adds one offset that the entry reads from `CLOCK_REALTIME` at its start, as the time page's wall offset does natively, so a later step of the host's clock does not reach ERTS, and wall time runs behind by the length of any sleep of the machine until the next start. `erlang:system_info(os_monotonic_time_source)` and `os_system_time_source` name these two calls as their functions, and report their unit as the resolution, since neither backend says how fine its clock ticks. The zone is UTC whatever the host's `TZ` says. `statistics(runtime)` fails with `notsup`, as on Fiasco, though the host could answer, so nothing comes to depend on it; no start path calls it.
* **The entry maps an archive.** `liberx/backend/hosted/start.c` holds `main(ARCHIVE, ARGS...)`: it `mmap`s the file read-only, closes it, runs `erx_pack_open` and the manifest reader, builds [the boot information page](#boot-information) and calls `erx_runtime_main`. A missing file or a refusal prints its reason and exits with status 1. A file truncated during the run faults, as the host's. `erx.*` words do not exist here: arguments after the archive's path are `init`'s.
* **The archive has a root that never runs.** `erx_pack_open` requires a root image and a manifest (`pack.c:405`, `:505`), and the packer sizes the root as an executable for the target. A hosted release is packed by the same `Pack#build`, with the same manifest and the same entries under `system/` and `domains/erxos/`, and a minimal static executable as `system/root` and again at `runtimes/emu`, so the manifest's references resolve as they do natively and hosted iteration needs neither Fiasco's build nor the cross-compiled ERTS; neither executable runs, since hosted the domain service makes no domain. A test compares the two archives' release files, path and hash, the root, the manifest and the notices excepted; `tools/lib/erx/release_files.rb` lists the files, each with a build receipt naming its source.
* **No watchdog.** A pet is accepted and does nothing, so a process stopped under `lldb` lives, and `erx_watchdog` runs as natively.
* **No domain library in one process.** The one-process form is the system domain alone and builds no library, as a domain's runtime builds none: both link `liberx/system/dom_lib_none.c` in its place, so the domain service's NIF module `erx_domain_lib` loads as natively and answers every well-formed call `{error, enotsup}`, and the domain service runs with no library. `erx_mem_create`, `erx_cap_close` and `erx_gate_bind`, which that module links for the library's crash copies and fault gate, are `ERX_ENOTSUP`.
* **The console's driver is `erx_stdio`** ([design-runtime.md](design-runtime.md#the-console-and-standard-io)).
* **Spaces other than the first are host processes**, so the rows between tasks run under the sanitizers: the first
  process holds the tables the root service holds natively and serves the others over a UNIX socket; a memory object is
  a shared memory region each process maps; an IRQ object fires by a message to the target process's dispatcher thread;
  a space's end is its process's, observed by the first process. It carries the rows between tasks that the domain
  library, connections and sessions use, and no device row, since a hosted runtime has no devices. The same function-API set runs against it, and
  the refusals are the native ones. Who walks a tree of exits children first, how a pass crosses processes and how a
  crashed process's objects are released are its design's to settle. Nothing above `liberx` sees which form ran.

## Transport

The function API is the seam. The `erx` backend's stubs trap into the kernel with the registers of `abi/arch/<arch>.txt`; here the same functions run locally or send
[a request](#the-root-service). No call number or register reaches a caller. The two wires differ in how they are made: every kernel
call's trap is generated from the ABI file, while [the service's wire](#the-root-service) has generated layouts under a hand-written
word-count table, since it ends with this backend.

**The public UTCB is not the native one.** `erx_utcb_self` returns the thread's public block, the start of its record, found through the native UTCB's first user word and the
register user mode can read. It has the ABI's `erx_utcb` layout, with `self` holding its own address and `reserved` zero. Fiasco's native UTCB is the backend's alone: its
`free_marker` occupies the offset of the public `reserved`, and each native call overwrites its message registers. So what a caller put in its public block survives any native
call, and no stub takes a snapshot of it.

## Read in source, never run

The QEMU gate's suites run the boot path, `sigma0`'s paging, the root's threads, tasks, memory,
interrupts and device windows under HVF at one and four CPUs, and the production image suite
compares two deterministic boots' transcripts byte for byte from erXos's banner to the shell's
line, Fiasco's own boot included. What this document rests on that no suite runs was read at the
cited lines and has not been executed; the first package that carries each claim checks it, and a
claim that fails changes this document.

**Speculation advisories**, fetched 2026-11-16 over HTTPS from Arm's Trusted Firmware-A repository
(`https://github.com/ARM-software/arm-trusted-firmware`, tag `v2.12.0`), since Arm's security
center at `developer.arm.com` refused the fetch with HTTP 403, and read as data:

* `docs/security_advisories/security-advisory-tfv-6.rst`, SHA-256
  `cddf5d0d8f1398cf75dfd28043f40ed6e3599152e8c8ea089a18c08e072e9331`, lines 39-70: the
  Cortex-A57 and Cortex-A72 need branch-predictor invalidation against CVE-2017-5715, which the
  firmware offers to the operating system as `SMCCC_ARCH_WORKAROUND_1`.
* `docs/security_advisories/security-advisory-tfv-9.rst`, SHA-256
  `6e1b762a610fb2f18a12e39b88e47af03bc5cc179a4fb6af0a0b68221fde0452`, lines 41-112: against
  CVE-2022-23960 the Cortex-A72 from r1p0 takes the loop workaround, and the firmware offers
  `SMCCC_ARCH_WORKAROUND_3` for the A72 through its CVE-2017-5715 workaround.
* `lib/cpus/aarch64/cortex_a72.S`, SHA-256
  `869759c3ffb6827b680b2398152b93ac431ed558ee1967e465b067ed5d81b15c`, lines 97-155: the A72's
  workarounds for both and `check_smccc_arch_workaround_3`.

Fiasco's `kern/arm` was searched for the SMCCC function identifiers `0x80008000` and `0x80003fff`,
for branch-history clearing and for `CSDB`, and none appears outside 32-bit code; `src/Kconfig`'s
prediction barriers (`INTEL_IA32_BRANCH_BARRIERS`, `:478-487`) depend on AMD64. The Raspberry Pi
4's A72 revision, whether 0.2's BL31 build turns the two workarounds on, and the exposure of the
Apple cores an HVF guest runs on are unverified.

**Other kernels' interfaces**, fetched 2026-11-23 over HTTPS and read as data, for
[Urgency](#urgency), "What the proven kernels do". No source of seL4's kernel was opened:

* seL4 13.0.0, `libsel4/include/interfaces/object-api.xml` (BSD-2-Clause), from
  `https://raw.githubusercontent.com/seL4/seL4/13.0.0/`, SHA-256
  `92a93445e77037231f4d2d0ab2f63cfe2e0b4da15165d5d6839f46e2f3e97de6`: `seL4_TCB_SetPriority`,
  lines 269-296; `seL4_IRQHandler_SetNotification`, lines 1262-1270; `seL4_SchedContext_Bind`,
  lines 1380-1393.
* Fuchsia at commit `7a9d8a69030a6afacfe970fd3df22fb11fcf0ebb`, from
  `https://fuchsia.googlesource.com/fuchsia`: `zircon/vdso/interrupt.fidl`, SHA-256
  `7724c05662cbb16903cae51cb5f149b439e765ed3e2985a767c9735346852dd9`, lines 232-257
  (`zx_interrupt_wait`); `zircon/vdso/object.fidl`, SHA-256
  `cd849207c17f42fe4738fde1d924f92cef7e074974541f4977466ec89d4fa0c4`, lines 2405-2422
  (`zx_object_set_profile`); `zircon/vdso/futex.fidl`, SHA-256
  `7e6cf3c8789821e572a86c9bbe5129fa4f13715c276c2cd7970ff4caecba8946`, lines 52-58
  (`zx_futex_wait`'s owner; the document on ownership and priority inheritance it points to was
  not read).

**Read, not run:**

* A fault never answered blocks its thread until deleted: `thread.cpp:582-584`; the fault paths not read.
* `enif_send` from a dirty NIF's callback, and its report of a dead receiver: `erl_nif.c:883`.
* A fire of an IRQ object bound to a thread that is not in an open wait stays queued at the thread and is received at its next
  `l4_ipc_wait`, one delivery a wait, a wait with a zero deadline included: `Irq_sender::send_local` and `send`,
  `irq.cpp:925-1009`; `Ipc_sender::send_msg`, `ipc_sender.cpp:176-181`; `Thread::do_ipc_receive`, `thread-ipc.cpp:775-787`.
* An edge-triggered line is acknowledged at its firing and masked only by a second edge before the first is received,
  and the receipt unmasks it: `irq.cpp:1044-1090`, `:751-776`.
* `l4_scheduler_run_thread` on a started thread changes its priority on its own CPU: `thread.cpp:695-711`, `:790-806`; not
  run for a thread whose scheduling context the root service is running on.
* ERTS's enqueue chooses a run queue in `select_enqueue_run_queue`, `erl_process.c:6500-6553`, for a wake, a spawn and a
  schedule-out (`:6886`, `:13013`, `:6675`, through `:6743`), and immigration, evacuation and the return of bound processes
  enqueue directly (`:4099`, `:4356`, `:4185`); a new port takes its opener's run queue, `io.c:346-353`; a block suspends
  every run queue but the first, `erl_process.c:8429-8431`, and a suspended scheduler runs aux work, `:7874-7897`.

**The rows between tasks**, each read for the first package that carries it:

* `l4_rcv_ep_bind_thread` by the root onto a thread of another task, with deliveries reaching that thread's open wait, and the
  root's stores into the task's memory before the bind visible to the thread after the delivery.
* `l4_task_map` into a task of the archive's pages, which `sigma0` mapped into the root read and execute, at read-only rights, and an image entry's code at read-execute rights.
* `L4_FP_OTHER_SPACES` over a page of the device window, removing every task's mapping of a register window.
* `L4_FP_ALL_SPACES` by the root over one physical object's range of the device window, removing the root's mapping and every
  mapping made from it and no other mapping of the same registers, which another object's range holds from `sigma0` apart.
* `l4_semaphore_up` by the service on a semaphore of a thread of another task, which the root holds at its own slot.
* `l4_irq_detach` by the root of an object bound to a thread of another task, and `l4_icu_bind` of a line whose earlier
  IRQ object was deleted, so a restarted device holder gets its line again.

## Measurements

Each is taken with `tools/erx bench` before and after the change, with the host, accelerator,
QEMU version, compiler, flags, workload and baseline recorded as CLAUDE.md requires:

* **a doorbell from ring to wake**, between two domains: a root round trip and a trigger before, a
  direct trigger after;
* **a service round trip**, the null request, to price what stays in the root, and, on the Raspberry Pi 4 with and
  without the branch-predictor patch, to decide whether the fork carries it
  ([The release's Fiasco build](#the-releases-fiasco-build), FD32;
  [todo-performance.md](todo-performance.md));
* **a connection's setup** by the domain library: its creations, placements and maps, since they
  move through domain factories;
* **the urgent scheduler's receipts**, on the Raspberry Pi 4: from Fiasco's interrupt entry to the
  driver's process in each cell of the interrupt measurement, with each cell's longest
  ([Verification](#verification)), the cost of a wake of the urgent scheduler by another
  scheduler, a trigger and a thread switch, and of its waits with a zero deadline at its process
  switches ([Urgency](#urgency);
  [todo-performance.md](todo-performance.md));
* **the boot with parks in place of spinning**, on the Raspberry Pi 4, with `+sbwt none` against
  `very_short`, which prices the rule that a wait blocks ([Scheduling](#scheduling));
* **lock-holder preemption without stage 2**: ERTS's spin time on its own locks with several
  domains on one CPU, which prices stages 1 and 2.

## What erXos's kernel keeps and drops

If erXos's kernel replaces Fiasco (M7 of [plan.md](plan.md), once gate GF chooses it), everything
above `liberx` stays: the interface, the runtimes, the services, the domain library and the system domain's policy, the
function-API set, the conformance and hostile suites, which grow to their full sets, and the bands'
order, which becomes the groups' urgency bases. Dropped: `liberx/backend/fiasco`, the root's
handle tables, the clean-room header, the Fiasco patches, the release's Fiasco configuration,
the system-call fuzz harness, the upstream watch, and this document's downsides table. A
scheduler stage built in the fork leaves its C17 policy core to erXos's kernel and drops its C++
hooks.

## Risks

| Risk | Likelihood | Impact | Response |
| --- | --- | --- | --- |
| a Fiasco defect reachable from a domain breaks isolation | medium | high | the fuzz campaign, the upstream watch, every domain holding only what the root placed; a defect found is fixed in the fork and reported |
| a platform 0.2 later supports puts a device behind an IOMMU that Fiasco's binding does not drive | unknown | medium | the device runs unconfined in a domain of its own, as every 0.2 device does (FD12), until its confinement case passes |
| bands alone give interactive latency worse than users accept | medium | medium | the band test and the latency benchmarks; stages 1 and 2 are the next steps |
| the release configuration drifts from the one tests run | medium | medium | the milestone gate runs the release configuration's suites, and the landing gate one smoke boot of it |
| two kernels to maintain while Track K is written | high | medium | Fiasco's part is the backend and a few patches; Track K writes against the same conformance suite |
| users take the downsides for bugs | medium | low | the table ships in the release notes and the user documentation |

## Open decisions

* **Whether ERTS publishes a hint under erXos's kernel.** The urgent scheduler closes, with calls
  that kernel has, the gap a published urgency leaves for an executor that is ready
  ([Urgency](#urgency)), and with it no normal scheduler holds urgent work, so `ERX_GROUP_HINTS`
  has no consumer in ERTS. Recommendation: one ERTS on both kernels, with the urgent scheduler and
  no published urgency, and the hint stays in [design-scheduler.md](design-scheduler.md) as a
  feature of configuration C2 that M8 keeps only if another runtime's measurement pays for it.
* **FD33: a device's input and a fault's reach on Fiasco.** The accepted deferral covers a domain's
  input alone: "nothing a domain does can panic the kernel" rests on Fiasco's own code and on what
  the system-call fuzz campaign checks (FD24). Whether a release also accepts that nothing a device
  does panics Fiasco, and that a fault ends only the faulting domain, only as far as Fiasco's own
  code gives it, with no erXos test driving that code, is not decided. Recommendation: accept it as
  a published downside for 0.2, since no device of 0.2's platforms is confined (FD12) and a
  misbehaving DMA-capable device already reaches the whole machine; add to the hostile suites'
  Fiasco set an interrupt storm on a driver's line, whose pass is that the machine and the other
  domains keep running, so the downside is measured rather than assumed. The fork's source adds to
  the evidence ([Patches](#the-releases-fiasco-build)):
  * **The entry.** AArch64's asynchronous-error vectors from user mode (`arm/64/ivt.S`, at `0x580`
    and `0x780`) enter `Thread::arm_serror_user_entry` (`arm/thread-arm.cpp`), which counts the
    error on its CPU and sends the running thread an exception carrying the SError's syndrome. The
    vectors from kernel mode (`0x180` and `0x380`) enter `Thread::arm_serror_handler`
    (`arm/thread-jdb.cpp`), which only counts it. The release build has both: `Modules.arm` turns
    on `arm_esr_traps`, the section of `arm_serror_user_entry`, for every 64-bit kernel, and lists
    `thread-jdb` with no condition on the debugger, where `arm_serror_handler` is in an
    unconditional `IMPLEMENTATION [arm]` section.
  * **What ends.** The root takes the exception as the fault kind `async_error`
    (`liberx/backend/fiasco/arch/aarch64/exception.c`) and handles it as any fault of a domain's
    task: the task ends, or the fault goes to its fault gate. In the root itself, an error while its
    main or runtime threads run ends the machine; its service and watchdog threads, whose exception
    handler is `sigma0`, resume with nothing recorded; and in `sigma0` the error is only counted.
  * **Whom it is charged to.** Without error records the architecture names no source, so the
    running thread's task is presumed the source. The kernel runs with SErrors masked, so one raised
    while a CPU is in the kernel is taken at the next entry to user mode on that CPU and ends that
    thread's task in the source's place, which may be another domain's.
  * **What is tested.** No erXos test raises an SError, since QEMU `virt` raises none a guest can
    cause; a host test checks the root's choice of fault kind. The fork ends an interrupt whose pin
    was unbound after another CPU acknowledged it, but a handler already bound to the software chip
    by then never ends that CPU's interrupt, a silent hang of the CPU that `TODO.md` records with the
    rest of this row's gaps.

  What a release would accept is then that an asynchronous error ends the task presumed its source
  or the machine, or passes unrecorded in two of the root's threads, and that every other path of
  Fiasco's interrupt and exception code, such as an interrupt storm on a line, rests on Fiasco's own
  code with no erXos test driving it.

Decided, and applied above:

* **No task but a test task writes a crash frame**: only the launcher's root-only `test_space_create` makes a space with
  no fault gate, and every other create refuses `ERX_CAP_NULL` as one, so every other task's fault reaches its creator's
  gate and after the handoff no domain's or session's frame reaches the kernel's ring
  ([The kernel's lines](#the-kernels-lines)). Writing a frame after the handoff into the log as records was the other
  choice, and it needed every frame reader to read a record's text.
* **The debugger keeps upstream's resume** after the handoff, a development-build limit FD26 publishes, and closes the
  route where it takes the console, `Jdb::open_debug_console`, so a breakpoint it only logs leaves the route as it is
  ([The kernel's lines](#the-kernels-lines)).
* **What shares out the task table**: the domains' object limits, counting every object a domain
  may make as a space, so the configured domains' and templates' object limits sum within the
  table's 1,024 rows ([Table sizes](#table-sizes)). If clause 9 comes to refuse a real manifest, the
  task table gains a row for every label instead, which keeps the cost inside the backend.
* **Where the figures clause 9 reads have one source**: `abi/erx_abi.txt`. The object space's
  slots, the root's window and the IRQ objects are its `fiasco_obj_space_slots`,
  `fiasco_root_handles` and `fiasco_irqs_max`, from which `root_layout.h` lays the root's slots out
  and derives the pool; the task table's rows are its `fiasco_task_rows`, which `service_task.c`
  checks by a static assertion against the row's size, as a spec writes down a layout's offsets and
  its generator checks them.
* **0.2's features** are Phase 1b and track A, and M9's devices, the rest of track P, M10, M12, track D's
  parts 5 and 9, and the security closure in its Fiasco form; track Q follows 0.2 (FD9).
* **Bands**: the five of [Bands](#bands): three a limits record names from the manifest's schema,
  and two the root task's own; their levels are one table of the backend, with no per-domain
  choice of priority beyond the band.
* **No rank among the configured domains**: the ordinary work of the system domain, the drivers
  and the interactive domains runs at one level, with the root service, and only urgent work runs
  above it ([Bands](#bands); FD15, FD17). Either rank starves someone whenever ordinary work does
  not end, and the lock that tied the root service to the system domain's priority blocks its
  waiter ([Locks](#locks)).
* **Urgency is built after the levels are measured**: the levels, the pinned schedulers, the 1 ms
  slice and the parks land first, changing no Fiasco code and no ERTS scheduling; the Raspberry
  Pi 4's measurement then runs with its loaded cells ([Verification](#verification)); and the
  urgent scheduler, with the bind to a thread, its wait and the request for a thread's level
  ([Urgency](#urgency)), is built when a loaded cell loses a byte, as the 1 ms slice against a
  0.7 ms FIFO says it will. Until then every thread runs at its band's base and a line is bound
  to its group. If no cell loses a byte, urgency waits for a consumer and stage 3 stays on the
  ladder.
* **The interactive band's ceiling is its base**, so a session, where a user's Erlang code can run
  a process at priority `high` without end, cannot keep a CPU from the base level, and the
  display's and a session's own devices are handled at the base, by a wake's preemption alone. A
  display domain whose device needs more is given the `driver` band in its limits record
  ([Bands](#bands)).
* **The boot's cost of parking** is accepted for 0.2, measured on the Raspberry Pi 4, and won back
  with stage 4's cheaper park; spinning on Fiasco's present park is the cause of the late receipts
  and is not offered as a setting ([Scheduling](#scheduling), "A wait blocks").
* **The mini UART driver's process runs at Erlang `high`**
  ([design-shared-devices.md](design-shared-devices.md), "The owner"), which with urgency built
  puts it on its runtime's urgent scheduler.
* **A call's slice is kept**: a call to the root service lends the service the caller's time, as
  Fiasco does it ([Scheduling](#scheduling), "A call's slice").
* **The pause**: the root's, stopping each thread, with no Fiasco patch
  ([Threads, bands and stops](#threads-bands-and-stops)).
* **The writable-or-executable patch** is carried
  ([The release's Fiasco build](#the-releases-fiasco-build)).
* **FD32's entry patch** is carried only if the null-request bench on the Raspberry Pi 4 shows it
  costs nothing measurable; otherwise FD32 is a published downside
  ([The release's Fiasco build](#the-releases-fiasco-build)).
* **Budgets** are hard walls at their guarantees; elasticity comes with erXos's kernel (FD25).
* **An app's session under hard walls**: on both kernels the domain service carves the app
  principal's budget from `apps` as a wall when it starts the app's session and destroys it once
  that session has retired ([design-packaging.md](design-packaging.md#an-apps-principal)), so no
  budget under `apps` is elastic and the backend needs no case of its own.
* **A hostile app's load on the root service** is a published downside of 0.2 (FD17).
* **The kernel's reads of what a domain supplies**, that it never loads or stores through an address
  a domain supplies and reads each user-writable field once per decision (K7), hold on Fiasco only
  as far as Fiasco's own code gives them, a published downside of 0.2 (FD24).
* **A space's handles and mappings** are one development-build inspection topic on both kernels,
  served on Fiasco by the backend reporter `liberx_placements` and partial where the root has no
  object id ([What a test reads of a task](#reporting-kernel-objects)).
* **A hang of Fiasco or of the root** resets the board through the power-management watchdog
  that the root's watchdog thread arms and reloads on every boot ([The watchdog](#the-watchdog)).
* **A missed pet and a root fault** reset the machine; neither turns it off
  ([The end path](#the-end-path)).
* **The toolchain** is LLVM 23.1.3 for Fiasco and for everything else, with no exception to the
  permissive link closure ([The release's Fiasco build](#the-releases-fiasco-build)).
* **The scheduler's stages**, the cooperation pieces and group quotas, follow once everything else
  works ([Stages beyond bands](#stages-beyond-bands)).
* **Fiasco's limits** are the downsides above, published with the release, never plugged by
  rebuilding a kernel mechanism in user mode.
