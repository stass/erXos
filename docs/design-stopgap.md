# The Phase 1 backend

Phase 1's kernel is Fiasco, near stock, imported under `fiasco/`.
`liberx/backend/fiasco` implements erXos's calls on it, in user mode, over
Fiasco's own calls. This document is that backend's design. It is the
current implementation behind an interface erXos owns: the generated C
functions of [design-runtime.md](design-runtime.md#the-liberx-interface),
defined by [design-kernel.md](design-kernel.md). At M7 the `erx` backend
replaces it behind those functions and nothing above `liberx` moves.

Two constructions carry the document, and most of what would be special
cases follow from them:

* **One owner.** The root task holds every Fiasco capability and every page.
  Every other task is a client of the root, and owns nothing it could leak
  or forget to free, so ending a task is a list the root walks.
* **One page, one address.** Each page of RAM has one permanent address in
  the root's pool window. Every mapping of a page, anywhere, derives from
  that address, so a mapping can come and go while the page and its contents
  stay.

## Contract

The owner's rules, verbatim:

> Phase 1 -- bring up the system on Fiasco maybe with small modifications.
> Get it to boot, basic filesystems work, services, shell, etc. Ignore
> security, robustness, scheduling eficiency, etc. Just needs to sorta work
>
> Phase 2 -- make our own kernel with all the guarantees

> In general we should not be plugging gaps in Fiasco that will go away with
> our kernel -- that's waster work and time

> So don't work around fiasco weakness unless cheap/easy/needed for our own
> kernel anyway

> whenever we keep hitting issues in the design, we should look how Fiasco, L4,
> Zircon etc solvedd it to see if we departed from a proven solution for no
> reason

> nothing gets shipped until I say so. So we just need to know where the
> gaps are, not necessarily fix them

From them:

* **What it promises**, for trusted workloads: the result in the last column
  of [the call table](#the-call-table), no memory errors, no deadlock, and
  exact accounting of whatever it reports.
* **What it refuses.** A call with no Phase 1 consumer returns `ERX_ENOTSUP`,
  and every caller checks for it. The hosted backend gives the same refusals.
* **What it reports as unknown.** A value only a kernel could know is
  `unsupported`, or `partial` with its reporter and scope, never a made-up
  number.
* **What it does not promise.** Isolation between domains, budgets as
  guarantees, quota enforcement, CPU grants, latency, behaviour under hostile
  load. [What Phase 1 defers](#what-phase-1-defers) lists each one and where
  it lands.
* **What may be in it.** Each mechanism names the Phase 1 consumer that needs
  it. Anything without one goes. The shapes are L4Re's wherever L4Re has one.

Claims read in source and never run are marked "(unverified)" and collected
in [Read in source, never run](#read-in-source-never-run). The first packages
test them on QEMU.

## Ownership and authority

Everything above `liberx` calls the generated functions, one per call, taking
values alone, plus the ABI file's types, status codes, limits and shared
layouts. Each function has two bodies, chosen when the image is linked: the
root entry's image links the direct bodies, which make Fiasco calls; every
other image links stubs that call the [root service](#ipc-gates-and-where-transfer-fits).
Calls that never need the kernel (umtx, `erx_park`, `erx_executor_wake`,
`erx_group_take_ready`, the time page) have one body, which runs locally.

### Capabilities in Fiasco's object space

The root holds a capability to every object it creates, with Fiasco's delete
right, so `l4_task_delete_obj` always reaches it. Callers hold **handles**:
indices in the backend's handle table, one table per task, kept in the root.
A handle is never a Fiasco capability value.

A task other than the root holds exactly these capabilities, all mapped by
the root with `l4_task_map` and rights `L4_CAP_FPAGE_RWS`:

| Slot | Object | Used for |
| --- | --- | --- |
| `L4_BASE_PAGER_CAP` | the task's handler gate | `_pager` and `_exc_handler` of each of its threads, which Fiasco resolves in the thread's own task at the fault (`thread-ipc.cpp:254,1020`) |
| the first slot after `L4_BASE_CAPS_LAST` | the task's service gate | every call that goes to the root |
| one per thread, from a counter | the thread's semaphore | umtx, park, reaper |

It holds no factory, scheduler, ICU, log or task capability, and no IRQ
object: an IRQ call from a task goes through the root service. The time page,
status pages and boot information page are mappings, not capabilities.

### Helper threads

The root creates and owns all of them. Each is backend C with no thread-local
storage, calls no musl function and takes no musl lock. A helper finds its
record through the first user word of its UTCB, as L4Re's pthread does
(`libpthread/src/descr.h:211`).

| Thread | Runs in | Does | Phase 1 consumer |
| --- | --- | --- | --- |
| root service | root | serves calls from other tasks | `libc-test` and BeamAsm test tasks |
| handler | root | receives page faults and exceptions of every thread | crash records (M3), a test task's fault |
| watchdog | root | steps `watchdog.c` over the pet word | M3's criteria |
| reaper | each task, one | deletes exited threads ([Deletion](#deletion)) | `pthread_join`, detached threads |
| dispatcher | the group's task, one per group | turns IRQ deliveries into triggers | console and block drivers, ERTS's wakes |

The reaper and dispatcher live in their task because what they touch is the
task's own: the UTCB area, which the root has no mapping of; musl's words; the
local umtx table and group record. So no thread reaches into another task's
memory and nothing wakes across tasks.

### Locks

All backend locks are spinlocks. A failed attempt yields with
`l4_thread_yield` (see [Scheduling](#scheduling)).

| Lock | Scope | Guards | Fiasco calls inside |
| --- | --- | --- | --- |
| root lock | root | range tables, pool, handle tables | yes |
| log sink lock | root | the log sink and the `l4_vcon_write` in progress | yes |
| umtx lock | one per task | the umtx table | none |
| reaper lock | one per task | the reaper's list, the UTCB slot list, the thread records | none |
| park lock | one per group | a group's epochs, parked list, ready ring | none |

No thread holds two. A wake or an `l4_semaphore_up` follows the unlock.

### The chokepoint

Fiasco's headers and capability values appear only under
`liberx/backend/fiasco`. A build check fails on a new site, and has a seeded
violation. Only the backend's Fiasco IPC exists: the root service, fault
messages and IRQ delivery.

## Boot handoff

**Bootstrap.** `bootstrap` is the first stage of the bootable file
([design-kernel.md](design-kernel.md#the-bootable-file)), and it changes in
one place: where its modules come from.

1. `erx_boot_locate` finds the archive and `erx_pack_open` validates it, or
   `bootstrap` stops with the reason, having copied nothing.
2. It finds three entries: the kernel at `boot_kernel_path`, `sigma0` at
   `boot_sigma0_path`, both fixed by the ABI file, and the root by the
   header's `root_entry`. `erx_pack_file_check` checks each.
3. A `Boot_modules` implementation presents the three as its modules, so
   inherited `startup()` runs as written: `add_elf_regions` and
   `load_elf_module` place each at its link address
   (`startup.cc:1013-1074`). The root and `sigma0` are static executables
   linked at physical addresses in RAM.
4. It reserves the whole archive, unmoved, and one handoff page as
   `Region::Root` regions of sub-type `Root_section_rwx`. These become
   bootloader memory descriptors, which `sigma0` keeps for the root
   (`init_kip.cc:80-82`, `init_mem.cc:71-77`).
5. The handoff page holds the image's flags, build identifier, index hash, the
   archive's address and size, and `/chosen/bootargs` cut at the last whole
   word within `boot_strings_max`. Its physical address goes in the kernel
   information page's `user_ptr`, the field inherited code uses for module
   information.

Fiasco's options stay on the kernel's module line, with neither `-serial_esc`
nor `-serial_input`, and the kernel is built without JDB (unverified: the
configuration names).

**The kernel.** It reads none of erXos's records, and carries one change of its
own, the two banner lines (`banner.cpp`). The fork's own kernel-call route
under `kernel/src/erx/` is not part of the Phase 1 kernel's build.
It starts `sigma0` and then the root (`std_workload.cpp`). The root starts with:

* capabilities at `L4_BASE_TASK_CAP`, `L4_BASE_FACTORY_CAP`,
  `L4_BASE_THREAD_CAP`, `L4_BASE_PAGER_CAP` (a gate to `sigma0`),
  `L4_BASE_LOG_CAP`, `L4_BASE_ICU_CAP`, which is also the platform control
  object, and `L4_BASE_SCHEDULER_CAP`;
* a stack pointer of 0, so its entry code sets its own, inside its image;
* one page of UTCB slots at an address the kernel chose, read with `l4_utcb()`;
* Fiasco's default priority, on the boot CPU, with the `sigma0` gate as pager.

**The root's first steps, in order.**

1. Sets its stack. Touching it faults to `sigma0`, which maps it one to one.
2. Maps the kernel information page with `l4sigma0_map_kip`, and from
   `user_ptr` the handoff page.
3. Maps its whole image and the archive at their physical addresses with
   `l4sigma0_map_mem`. **After this step no page of the root is mapped on
   demand**, which step 5 relies on.
4. Builds the pool window ([Budgets](#budgets-and-the-ownership-of-pages)).
5. Creates its handler gate and handler thread, and points its own thread's
   `_pager` and `_exc_handler` at the gate. From here a fault in the root is a
   crash record, not a silent mapping from `sigma0`. The handler's own pager
   stays the `sigma0` gate.
6. Starts its reaper, the root service and the watchdog.
7. Reads the manifest through its generated C reader; fills the time page;
   seeds `rng.c`; writes its boot information page, flagged `ERX_BOOT_ROOT`.
8. Prints the build identifier and index hash through `l4_vcon_write`, and
   enters musl's start path, which runs ERTS.

**Boot information.** The ABI's `erx_boot_info` layout is kept. `budget`,
`space`, `group`, `group_ctl`, `group_stat`, `time_page` and `release` hold
handles. `crash_area` and `system_connection` hold zero, because Phase 1 has
no object behind them. The launcher writes a test task's page the same way and
maps it read-only.

A failure in steps 1 to 7 prints its reason and ends the machine with
`l4_platform_ctl_system_shutdown`; before step 5 there is no crash record.

## The Phase 1 manifest check

Two things stop a production image without it: `Admitted.admit` refuses every
manifest for `root_startup` (`manifest.rb`, and `Pack#build` requires the
admitted bytes), and before that `EmptyNative#check` refuses a full boot and
every `domain`, `partial_boot`, `window`, `service`, `facet`, `introduce`,
`image` and `liveness` record. **`SystemOnly`** sits beside `EmptyNative` and
shares its readers: a development manifest, full or partial boot, with the
system domain alone. It accepts the records the system release's services need
and refuses `domain` and `partial_boot` records with a diagnostic naming the
milestone that brings them. Its scope, against
[design-system.md](design-system.md)'s properties, each kept property with a
seeded violation and each refusal with a seeded record:

| Property | Phase 1 | Whole again at |
| --- | --- | --- |
| 1 one holder per device and unit | kept; every holder is the system domain | |
| 2 facets name servers | kept, over the system release's services; no introductions | M5 |
| 3 PCIe configuration space | QEMU `virt` drives no bridge in Phase 1, so no holder is allowed | M9 |
| 4 budgets and grants sum | kept for `root_memory`, baseline and shares, `max_domains` 0; `root_startup` by the rule below | Track K (`root_startup`), M5 (`max_domains`) |
| 5 names | kept | |
| 6 no JIT in the root | kept | |
| 7 the sealing secret | `sealing` is `none`, no entry carries `ERX_ENTRY_SEAL`, no TPM | M11 |
| 8 partitions and devices reach holders | the UARTs part kept; the system domain holds the slot and data windows, as M6 places them; no vault partition, no network device | M9 (storage domain), M11 (vault) |
| 9 a release build's confinement | release builds refused; the unconfined block device is allowed | M11 |
| 10 boot order, 11 rescue, 12 child domains, 13 headroom | no configured domains, so nothing to check; `domain` records refused | M5 |

**The root startup rule** is a sanity check, not a proof: the root entry's
loadable segments plus `system_baseline` fit `root_memory`, and `root_memory`
fits the platform's RAM less `fiasco_reserve`. `fiasco_reserve` is a number in
the platform record, taken from what `sigma0` offers the root at the harness's
RAM size. If it is wrong, the pool fails at boot with a diagnostic. The
`Admitted` value records `root_startup: declared` in its report, and
`erx_root_plan` replaces the rule behind the same value in Track K.

A test task's program is a boot-image entry named by the boot argument
`erx.test=PATH`, not a `partial_boot` record.

## The call table

Every consumer kept in Phase 1 has a row; `ERX_ENOTSUP` answers everything
else. Fiasco's calls are in `fiasco/l4re-core/l4sys/include/`.

| erXos call | Phase 1 consumer | Body | Result |
| --- | --- | --- | --- |
| `erx_vm_reserve`, `erx_vm_commit`, `erx_vm_decommit`, `erx_vm_release`, `erx_space_protect` | musl `malloc`, ERTS allocators, thread stacks | [Budgets](#budgets-and-the-ownership-of-pages) | correct contents; `ERX_ENOMEM` from the pool; write and execute together refused `ERX_EINVAL`; a touch of a decommitted page faults to the handler |
| `erx_mem_create(budget, size, flags)`, `erx_vm_map(space, addr, size, mem, offset, prot)` | BeamAsm's JIT object in its test task; `liberx`'s mapping of the time page and a group's areas | pages from the pool recorded as an object; each map is `l4_task_map` from the pool window. `ERX_MEM_JIT` only from a task created with `ERX_SPACE_JIT` | correct; `erx_mem_grow`, sealing `ERX_ENOTSUP` |
| cache maintenance, the code barrier | BeamAsm | none: user mode may run them, so asmjit's and ERTS's sequences run unchanged ([design-arch-aarch64.md](design-arch-aarch64.md)) | correct |
| `erx_mem_create_physical(budget, resource, range, attr)` | the device NIF: UART (M3), virtio-mmio block (M6) | `l4sigma0_map_iomem(pager, phys, virt, size, 0)` into the root at an address the range table reserved; the resource comes from the manifest's device entry. The console UART's create is also the [console handoff](#the-console) | correct; a second `erx_vm_map` `ERX_ENOTSUP` |
| `erx_mem_create_contiguous(budget, resource, size, limit)`, `erx_mem_dma_addr(mem, offset)` | the device NIF's buffers and rings (M6) | carved first-fit from a [contiguous pool](#the-pool), aligned to its size rounded up to a power of two, at most 1 MiB, normal cached memory. `dma_addr` is the recorded physical address plus the offset: unconfined DMA, the stopgap's driver profile | correct; `erx_dma_map`, windows `ERX_ENOTSUP` (M9) |
| `erx_irq_create(budget, resource, kind, selector)`, `erx_irq_bind(irq, group, label)`, `erx_irq_ack`, `erx_irq_trigger`, `erx_irq_route` | console (M3) and block (M6) drivers, `{erx_irq, Device, Line}` sinks; software objects for ERTS's wakes | create: `l4_factory_create_irq` and, for a line, `l4_icu_bind` on `L4_BASE_ICU_CAP`. Bind: `l4_rcv_ep_bind_thread(irq, dispatcher, record)`. Ack: `l4_irq_unmask`. Trigger: `l4_irq_trigger`. Route: recorded, not applied | each label once, the line masked until acked; routing reported as not applied |
| `erx_group_create`, `erx_group_configure`, `erx_group_info`, `erx_group_take_ready(max)` | the adapter's five changes (M3) | a record in the group's task: [Interrupts and readiness](#interrupts-and-readiness). `configure` records and enforces nothing. `info` reports capacity as the pinned CPU set, usage `unsupported` | correct readiness; no CPU guarantee, quota or throttling |
| `erx_park(group_epoch, slot_epoch, deadline)`, `erx_executor_wake(slot)`, `erx_yield` | ERTS's schedulers (M3) | [The park protocol](#the-park-protocol); yield is `l4_thread_yield` | no lost wake |
| `erx_umtx_wait(addr, expected, deadline)`, `erx_umtx_wake(addr, count)` | musl's futexes, under ERTS and `libc-test` | [The umtx table](#the-umtx-table) | correct within a task; the table is per task, and nothing in Phase 1 waits across tasks |
| `erx_thread_create(budget, space, group, class)`, `erx_thread_start`, `erx_thread_exit`, `erx_thread_set_affinity` | `pthread_create`, ERTS's executors and dirty schedulers, `libc-test` | [Thread creation](#thread-creation), [Deletion](#deletion); affinity is `l4_scheduler_run_thread` with the mask | correct; `erx_thread_stop`, `_read`, `_write`, `_set_urgency` `ERX_ENOTSUP` |
| `erx_space_create(budget, parent, fault, label, flags, cap_limit)`, `erx_space_stop(space, status)`, `erx_image_map(space, slice, entry)` | the test-task launcher in the root (`libc-test` at M3, BeamAsm at M4) | `l4_factory_create_task(factory, cap, utcb_area)`; segments through `elf_plan.c`, copied through the window, cleaned and invalidated from the caches, mapped at the plan's addresses, code read-execute and data read-write; [Deletion](#deletion) for stop. `parent`, `fault`, `label` recorded | a "domain" is a task with no budget, grant, lanes, facets or exit record; `erx_space_pause`, `_resume`, `_clear_caps`, `_quiesce`, `_copy` `ERX_ENOTSUP` |
| `erx_cap_dup`, `erx_cap_close`, `erx_object_destroy`, `erx_object_info` | Erlang NIF handles, the launcher | the handle table; destroy deletes the Fiasco objects with `l4_task_delete_obj`, and for memory revokes every mapping first. Destroying a started thread, other than by its reaper, `ERX_ENOTSUP` | correct; `erx_cap_pass` `ERX_ENOTSUP` (no second domain) |
| `erx_budget_create`, `erx_budget_resize`, `erx_budget_watch` | the domain library's root entry (M3), the inspector | a page count per budget: [Reporting a budget](#reporting-a-budget) | no fabrication; resize, watch `ERX_ENOTSUP` |
| the time page, `erx_time_set_wall` | ERTS's time, deadlines | a page the root fills, mapped read-only into every task: the counter's scale, from the architecture's user-readable counter, and the wall offset from the manifest. A deadline converts as in [Deadlines](#deadlines) | correct layout |
| `erx_entropy_read`, `erx_entropy_add` | ERTS's `crypto` seed, the host link | `rng.c`, seeded from the counter and the manifest's seed | `quality: low` in the banner |
| `erx_debug_log` | `liberx`, ERTS's crash path, test tasks | [The console](#the-console); a task logs through the root service | correct |
| `erx_watchdog_pet`, crash record, `erx_machine_end` | M3's criteria | [The watchdog](#the-watchdog-the-crash-record-and-the-console) | correct, except for a kernel hang or a stall of the watchdog thread |
| IPC gates, messages, lanes, `erx_mem_copy`, `erx_mem_child`, paged objects, `erx_vcpu_*` | none | refused | `ERX_ENOTSUP` |

The hosted backend implements the same rows with the same refusals, so ERTS's
port runs hosted first (Track H), and both backends pass one function-API test
set, which seeds Track K's conformance roster.

## Budgets and the ownership of pages

### The pool

The root takes RAM from `sigma0` at boot, in step 4 of the boot sequence, and
keeps all of it:

1. As many **contiguous pools** as the manifest's device entries ask for, each
   one 2 MiB superpage from `l4sigma0_map_anypage(pager, window_cursor, 21,
   &phys, 21)`. Each pool records `phys`, the reply's base. QEMU `virt` is
   coherent, so normal cached memory serves.
2. Everything else, the same call asking for 2 MiB until `sigma0` refuses and
   then 4 KiB until it refuses again. `sigma0` maps RAM read, write and execute
   (`memmap.cc:96,125`).

The window starts at a constant of the backend's address layout, above all RAM,
and is never unmapped. **A page's identity is its window address.** Nothing but
a contiguous pool needs a physical address, so nothing else records one. Free
pages are a list threaded through the pages themselves, and a page is zeroed
when taken, through the window. An exhausted pool is `ERX_ENOMEM`.

A window superpage serves as a parent for page-sized mappings
(`map_util.cpp`, the `to_fit_size` loop; unverified).

### The range table

One table per task, kept in the root, under the root lock. It is a pure core:
it reads no global state, builds for the host and returns plans. Each record is
a reserved range, and each of its pages is either *uncommitted* or *committed*
with a window address, and has a protection. Mapped shared objects get a record
per mapping, naming the object's pages.

Every call computes a whole plan first (a list of take-page, zero, map and
unmap steps, with the number of pages it needs), refuses it if the pool cannot
cover it, and only then applies it. So a refused call has changed nothing.

* **Commit** (`erx_vm_commit`), in the root and a task alike: take a page, zero
  it, and `l4_task_map(task, L4_BASE_TASK_CAP, l4_fpage(window, L4_PAGESHIFT,
  prot), l4_map_control(addr, 0, 0))`. Mapping is eager: a committed page is present.
* **Decommit:** `l4_task_unmap(task, l4_fpage(addr, L4_PAGESHIFT, L4_FPAGE_RWX),
  L4_FP_ALL_SPACES)`, and the page goes back to the pool.
* **Release:** decommit what is committed, drop the record.
* **Revoke** (destroying a shared object):
  `l4_task_unmap(L4_BASE_TASK_CAP, l4_fpage(window, L4_PAGESHIFT, L4_FPAGE_RWX),
  L4_FP_OTHER_SPACES)`, which leaves the root's own window mapping and removes
  every mapping derived from it, then the pages go back to the pool.

### Protection

`erx_space_protect` works on the page's record, not on a mapping, so a change
of protection cannot lose contents. Fiasco offers two directions:

* **Dropping** a right is `l4_task_unmap` with that right in the flexpage.
* **Raising** is `l4_task_map` of the same window page at the same address.
  Fiasco finds the same page already mapped there as a child of the sender and
  takes it as an upgrade: **rights are added to the existing ones, never
  replaced** (`map_util.cpp:643`, `mem_space-arm.cpp:241`), and no entry is
  invalidated when memory type does not change (`page-arm.cpp`,
  `is_attribs_upgrade_safe`). So a map can never lower a right, and a change in
  both directions must drop first.

Write means read and write, execute means read and execute. Write and execute
together are refused `ERX_EINVAL` before any step.

| From | To | Steps, in this order |
| --- | --- | --- |
| uncommitted | no access | record only; the page stays uncommitted |
| uncommitted | R, RW or RX | take a page, zero it, map it with the target. This is K4's commit on access change, and musl's guarded stack: `__mmap(PROT_NONE)`, then `__mprotect` (`pthread_create.c:295-297`) |
| no access | R, RW or RX | map the same window page with the target |
| R | RW or RX | map the same window page with the target |
| RW or RX | R | unmap the write or the execute right |
| RW | RX | unmap write, then map the window page RX |
| RX | RW | unmap execute, then map the window page RW |
| any | no access | unmap all rights; the page stays committed, its contents kept |

Pages change in ascending address order, one at a time, under the root lock.

**A thread touching a page during a change.** Read stays allowed through a
RW-to-RX or RX-to-RW change, since only the other right moves. A write or
instruction fetch that overlaps the change, or a touch that overlaps a change to
or from no access, faults to the handler, which ends the task or the machine.
That is the touching thread's bug, as it raced its own `mprotect`.

**The root as sender and receiver.** The root's own ranges use the same call:
`L4_BASE_TASK_CAP` as both destination and source. Source reading supports it:
`Lock_guard_2` takes one lock when both tasks are the same
(`lock_guard.cpp:255`), and the mapping database matches a mapping by space and
address, so two addresses in one space are distinct mappings. It has never been
run, and the first memory test runs it. If Fiasco refuses it, the root's own
ranges map from `sigma0` with `l4sigma0_map_mem` of the page's physical address,
which then has to be kept for each page, and tasks keep the window path.

### Shared objects and the JIT alias

A shared object is an array of window addresses. `erx_vm_map` makes a record in
the target task's range table and maps each page with the requested rights, so
writing through a read-write alias and running through a read-execute one is
two mappings of one window page. No mapping holds write and execute at once.
The pool window itself is read, write and execute in the root, which is the
stopgap's residual. So M4 checks the range table and tests each JIT alias by a
fault, and the page-table walk belongs to M7.

### Reporting a budget

A budget is a counting record: pages the pool handed out under it.
`erx_object_info` reports `used` with status **partial**, reporter `liberx
pool`, scope "pages committed through `liberx`; not kernel objects, page tables
or mapping records". `guarantee`, `cap`, `carved`, `lent` and `pinned` are
`unsupported`.

### Kernel memory and the root budget

Fiasco's objects, page tables and mapping records come from its own allocator,
sized at boot, and are charged to nothing erXos can see. A Fiasco call that
fails for lack of it returns `ERX_ENOMEM`. What Fiasco does when a path that
cannot fail meets exhaustion is inherited.

## Threads, waits and exit

### Scheduling

Fiasco's fixed-priority scheduler schedules every thread; ERTS schedules its
processes within them. There are two priorities:

* **The common priority**, Fiasco's default of 1, for every thread that takes a
  backend spinlock, which is every thread but the watchdog. It is what the root's
  first thread and `sigma0` already run at, so a call on `sigma0` can never be
  starved by its caller's siblings. A spinner never outranks a preempted holder
  on its CPU, and it yields to the holder.
* **The top priority**, 255, for the watchdog, which takes no lock.

`l4_scheduler_run_thread(L4_BASE_SCHEDULER_CAP, thread, &param)` starts each
thread, with `param` from `l4_sched_param(priority, 0)` and the CPU mask in
`param.affinity`.

### Thread creation

**`erx_thread_create`** gives a stopped thread: in the root, for any task,
`l4_factory_create_thread` and `l4_factory_create(factory, L4_PROTO_SEMAPHORE,
cap)` (`factory.h:470`, `semaphore.cpp:329`), and the semaphore mapped into the
task. The caller's task keeps a **thread record** in a fixed table of its own:
the starting registers, the handle, the semaphore's slot, the group slot, the
word to clear and the range to release. The record never lives on the thread's
stack. The thread has no UTCB yet. A task may name only itself as the space, and
the root may name any; another space from a task is `ERX_ENOTSUP`. A full table or
a failed Fiasco call is `ERX_ENOMEM`.

**`erx_thread_start`** does the rest in one step. Binding waits for the start
because a bound thread that never ran is destroyed by `unbind()` alone, with no
kill and so no `free_marker` write (`thread_object.cpp:161-164`). Holding the
slot back means a thread that never started has no slot to lose.

1. The caller's task claims a UTCB slot (below), and writes the marker 1.
2. It writes the start frame on the new stack: thread pointer, entry, argument,
   record pointer.
3. The root does `l4_thread_control_start`, `_pager` and `_exc_handler` both
   naming the handler gate's slot, `_bind(utcb, task)`, `_commit`; then
   `l4_thread_ex_regs(thread, trampoline, sp, 0)`, then
   `l4_scheduler_run_thread`.

A failure at step 3 writes the marker 0 and returns the slot. Starting a thread
twice is `ERX_EINVAL`.

**The trampoline.** `l4_thread_ex_regs` carries no thread pointer (`thread.h:94`),
so `ip` is `liberx`'s start trampoline, a few lines of assembly in the backend's
architecture layer: it sets the thread-pointer register, which user mode may
write and Fiasco saves per thread, stores the record pointer in the UTCB's first
user word, writes the marker 1, and calls the entry with the argument. Writing
the marker again is what a thread the root started needs, since the root cannot
reach a task's UTCB page.

**UTCB slots.** Fiasco writes `free_marker` when it is finished with a UTCB,
which happens in `do_kill`, some time after the deletion call has returned
(`thread.cpp:603-604`). So the slot's state is in two places, and the claim checks
both, as L4Re does (`manager.cc:541`, `internals.h:285-294`):

| State | On the free list | `free_marker` | Claimable |
| --- | --- | --- | --- |
| in use | no | 1 | no |
| freed by the reaper, Fiasco not finished | yes | 1 | no |
| free | yes | 0 (`Utcb::Free_marker`, `l4_types.cpp:791`) | yes |

The list belongs to the task's backend, under its reaper lock. A claim walks it
and takes the first slot that loads 0. **If no slot qualifies, it adds a page of
slots rather than wait**, as L4Re does (`manager.cc:505-535`): the root calls
`l4_task_add_ku_mem(task, &fpage)` at the next page of the task's UTCB range, and
the task writes 0 in each new slot's marker. A range is a constant of the address
layout. Past its end, or if Fiasco has no memory, the call is `ERX_ENOMEM`. A
page of slots stays with the task until the task ends, which bounds it by the
task's peak thread count plus the threads Fiasco has not finished killing.

A new task starts with one page of slots (`l4_factory_create_task`'s
`utcb_area`). The root binds its first thread to slot 0 and its reaper to slot 1,
through the same steps, writing their start frames through the window; the first
thread's backend initialisation puts the page's other slots on the list. The root
itself does the same with the page Fiasco gave it.

**Musl's thread identifier.** `self->tid` is the thread record's index plus one.
`__tl_lock` stores it in `__thread_list_lock` with `a_cas(.., 0, tid)`, so it must
be nonzero, and `pthread_mutex_trylock.c:8-12` compares it to `_m_lock & 0x3fffffff`,
so it must fit in 30 bits. The record is freed only after the reaper's last step,
so no live thread shares an identifier with a stale lock word.
`SYS_set_tid_address` (`__init_tls.c:22`) and `__clone` store the address they are
given as the record's word to clear.

### The umtx table

One table per task, in the task's own memory, keyed by address, under the umtx
lock. It is a pure state machine run by a thin layer, and shared with the TSan
model. Each waiter is a node in its thread record.

* **Wait** `erx_umtx_wait(addr, expected, deadline)`: under the lock, load `*addr`.
  If it differs from `expected`, return `ERX_OK` without waiting (musl treats that
  as a spurious wake). Otherwise enqueue. After the lock,
  `l4_semaphore_down(own, timeout)`.
* **Timeout:** when the down returns `L4_IPC_RETIMEOUT` (`restart.h:81`), take the
  lock. If the node is still queued, remove it and return `ERX_ETIMEDOUT`. If a
  waker has already dequeued it, its up is on the way: absorb it with an unbounded
  down and return `ERX_OK`.
* **Wake** `erx_umtx_wake(addr, count)`: under the lock, dequeue up to `count`
  waiters in the order they queued. After the lock, `l4_semaphore_up` each. It
  returns how many it woke.

**An invariant shared with [the park protocol](#the-park-protocol): a thread taken
off a list is owed exactly one up, and only such a thread is.** So a semaphore
holds 0 whenever its thread enters a wait, no stale count survives, and a thread
taken off a list cannot go on until its up arrives, which keeps its record valid
for the waker that holds the semaphore's slot after the unlock.

No lost wake: a wait compares under the lock, and a waker stores the word before
it takes the lock, so either the waiter sees the new value or the waker sees the
node.

`ERX_EINTR`, `ERX_ESTALE` and `ERX_EFAULT` do not occur: no events, no destroyed
word's object while a thread of the task runs, and a bad address is a fault to the
handler. A word in memory shared between tasks gets no refusal, because the table
cannot tell: a wake from another task finds no waiter. Nothing in Phase 1 shares a
word.

### Deadlines

A deadline is absolute monotonic nanoseconds. The backend reads the time page,
takes the remainder, rounds it up to microseconds and passes
`l4_timeout_from_us`, which itself rounds up to the next value Fiasco can hold
(`__timeout.h:292`), as the receive timeout, with `L4_IPC_TIMEOUT_NEVER` for no
deadline. So a wait is never early, and is late by up to Fiasco's timer granularity
plus one part in 512. A deadline already past returns without a kernel call.

### Deletion

#### Thread exit

L4Re's libpthread is the proven shape: a per-task manager thread, not the exiting
thread, deletes the kernel object and frees the resources
(`libpthread/src/join.c:83-87`, `manager.cc:201-214`). The backend copies it. The
reason for the order is that an exiting thread is running on the stack and UTCB
to be freed, and that musl's lock word has to outlast its owner.

**Exit.** `erx_thread_exit` takes the reaper lock, puts the thread's record on the
reaper's list, unlocks, `l4_semaphore_up(reaper)`, and sleeps forever in an IPC
wait with `L4_IPC_NEVER`. It does not touch the record afterwards.

**The reaper's steps, in this order, for each record.**

1. **Delete.** `reap(handle)`, directly in the root and through the root service in
   a task, runs `l4_task_delete_obj` on the thread and on its semaphore. That reaches
   `Thread_object::destroy` before the call returns (`thread_object.cpp:157-166`, and
   `Reap_list::del` in `sys_unmap`'s destructor, `kobject.cpp:224-233`). `Thread::kill`
   returns once the thread's home CPU has taken the request, and from then on the
   thread never returns to user mode (`thread.cpp:657-690`). So its stack and thread
   storage are free (unverified: never exercised).
2. **Release.** If the record names a range (a detached thread), `erx_vm_release` it.
3. **Clear.** Store 0 in the record's word to clear and call `erx_umtx_wake(word, 1)`.
4. **Recycle.** Put the UTCB slot on the free list, with its marker as Fiasco leaves
   it, and free the record.

The reaper holds no lock across these, and step 1 cannot be refused for a thread
of its own task; a refusal is a crash record. Between steps 1 and 3 nothing can create
a thread with the same identifier, since `pthread_create` holds `__thread_list_lock`
across `__clone`.

**Join: musl's code stays.** The word to clear is `&__thread_list_lock`, the
contract of Linux's exit futex address that `pthread_create.c:142-146` relies on. As
on Linux:

1. `__pthread_exit` takes `__tl_lock`, sets `self->tid` to 0, and unlinks itself.
   The lock word still holds the old identifier, and nothing unlocks it.
2. It stores `DT_EXITED` and wakes the joiner (`:169-170`).
3. The joiner's `__tl_sync` (`pthread_join.c:22`, `pthread_create.c:45-52`) sees a
   nonzero lock word and waits on it.
4. The exiting thread calls `erx_thread_exit`, in place of the
   `for (;;) __syscall(SYS_exit, 0)` tail. That is the only change.
5. The reaper's steps 1 and 3 delete the thread and then clear and wake the word.
6. The joiner returns from `__tl_sync` and only then calls `__munmap` on the stack
   (`pthread_join.c:24`), which therefore follows the deletion. Every other
   `__tl_lock` caller is released the same way, and `__tl_sync` passes the wake on.

The reaper must not wait on the lock it clears: it calls no musl function, so it
takes no musl lock, and the root lock's holders take none either.

**Detached.** `__unmapself` (`pthread_create.c:165`) becomes
`erx_thread_exit_release(base, size)`, a private `liberx` entry that puts the range
in the record and then does as `erx_thread_exit`. `__vm_wait` above it (`:83`) stays.
Step 3 still clears the lock word.

**Condition variables.** In `unlock_requeue` (`pthread_cond_timedwait.c:48-53`), `w`
is `m->_m_type & (8|128)` (`:157`): musl already wakes the next waiter, instead of
requeueing it, for priority-inheriting and process-shared mutexes. The port always
takes that branch and deletes `FUTEX_REQUEUE`. Each woken waiter takes the mutex with
`pthread_mutex_lock` and then releases the next waiter's barrier, so a broadcast
stays a chain of single wakes. The umtx table needs no requeue, nor does Phase 2's
kernel umtx. The cost, one extra wake per waiter, is on
[the performance watch list](todo-performance.md).

#### Task exit

Deleting a task capability does not delete the threads, which the root holds and
which keep references to the task (`task.cpp:686-699`, `thread.cpp:306`). So exit is
a sequence the root runs, under the root lock, and nothing else ends a task:

1. **The cause.** The task's thread calls `erx_space_stop(ERX_CAP_SELF, status)`
   through the root service, which musl's `exit` does; the root calls
   `erx_space_stop(task, status)`, the launcher's end of a test; or the handler, on a
   fault, writes the crash record and calls `erx_space_stop(task, fault)`.
2. **The threads.** `l4_task_delete_obj` on each thread of the task, newest first,
   its reaper and dispatchers included. Each may be blocked, running or ready; when the
   call returns it can never return to user mode. So after this step no thread of the
   task runs user code. No reaper step is needed, since the UTCB area and every word
   go with the task. A thread killed in a call on the root service has its reply
   dropped, because the reply's send timeout is zero.
3. **The objects.** The task's IRQ objects, its semaphores and its gates, then the
   task object. `Task::destroy` unmaps everything before the call returns
   (`task.cpp:686-699`).
4. **The memory.** The task's pages return to the pool and are reusable from here.
   Its objects are released and its range and handle table records freed.
5. **The status** goes to whoever started the task: the launcher's C caller, as a
   test's transcript line.

`erx_space_stop(ERX_CAP_SELF, status)` in the root is `erx_machine_end`. Step 2 takes
Fiasco's RCU grace period per thread, with the root lock held; a thread spinning on
the lock yields into the kernel, so the grace period is not held up (unverified).

This does not promise a completion bound under hostile load. No task holds a mapping
into another: the only pages two tasks share are the status and time pages, which the
root owns.

## Interrupts and readiness

A group is a backend record in its task: its executor slots, status page, park lock,
parked list, ready ring, listed flags and dispatcher thread.

**The dispatcher** blocks in `l4_ipc_wait(utcb, &label, L4_IPC_NEVER)`. Every message
is one IRQ object firing, whose label is the index of that object's record in the
group, which `erx_irq_bind` chose and gave to `l4_rcv_ep_bind_thread`. It runs a
trigger for that record, then waits again. It sends nothing back, and takes the same
path for a device line and a software `l4_irq_trigger`.

**The ready ring** has one entry for each bound object, and an object is on it at most
once, by its listed flag, so it cannot overflow and a trigger allocates nothing.

**`erx_group_take_ready(max)`** drains up to `max` entries, at most `ERX_MSG_WORDS`,
into the caller's result under the park lock, clears their flags and mirrors `ready`.
The caller's labels come from the records.

**Ack.** A device line stays masked from its delivery until `erx_irq_ack`, which is
`l4_irq_unmask` through the root; this is Fiasco's own behaviour for a bound IRQ
object (unverified).

### The park protocol

The design's protocol ([design-scheduler.md](design-scheduler.md)) is kept, with a
semaphore in place of the kernel's switch; the executor's loop above `erx_park` does
not change. L4Re's pthread uses one semaphore per thread in the same way
(`restart.h:26-37`). The four operations are one pure state machine, `park_step`,
over the group's state: the group's epoch, each slot's epoch, the parked list in
order, the ready ring, the listed flags. It reads no clock and makes no Fiasco call;
it returns what the caller does after unlocking, and both the TSan model and the
exhaustive test run it.

| Operation | Under the park lock | After the lock |
| --- | --- | --- |
| **Trigger**(object), by the dispatcher | list the object unless listed; mirror `ready`; advance the group's epoch and mirror it; take the longest-parked slot, if any | up that slot's semaphore |
| **Park**(slot, g, s) | if the group's epoch differs from `g` or the slot's from `s`, return `ERX_OK`; otherwise join the parked list | `l4_semaphore_down` with the deadline |
| **Timeout**(slot) | if still on the list, leave it and return `ERX_ETIMEDOUT`; if taken off, return "owed" | if owed, an unbounded `l4_semaphore_down`, then `ERX_OK` |
| **Wake**(slot) | advance the slot's epoch and mirror it; if on the list, take it off | if it was taken off, up its semaphore |

The caller of `erx_park` is the one whose slot it names, and a worker is refused
`ERX_ETYPE`.

**No lost wake.** The executor reads the epochs before its empty check. A trigger
between that check and the park advances the group's epoch, so the park returns at
once. A trigger after the park finds the slot on the list. The same two cases hold
for a wake and the slot's epoch. With no slot parked, a trigger ends there, and a
running executor finds the work at its next safe point: it either has not yet read
the epoch, or will fail the park's comparison.

**No stale count.** An up goes only to a slot taken off the list, and a slot taken
off the list consumes exactly one down, in the park's own down or the timeout's
absorb. So every semaphore holds 0 at every park.

### The trace ring

M4's `erx:trace` needs a timeline of ERTS's scheduling and the backend's events.
The backend writes park, wake, IRQ delivery, task start and task end to one ring of
the inspector schema's records, in the root. The kernel's row reports `unsupported`.
Since the format is the schema's, Phase 2 adds a source, not a format.

## IPC gates and where transfer fits

No IPC gate is offered above `liberx`. Fiasco IPC is the backend's own transport,
in three places: the root service, faults, and IRQ delivery. A Phase 1 program sees
none of it: gates, messages and lanes between domains are refused, and capability
transfer does not exist, since the one owner never hands a capability on. This is
`moe`'s shape on L4Re, not a second kernel: the root service implements only the
table's rows and holds no budget, exit record or gate for Erlang code.

### The root service

**One gate per task**, all bound to the one root service thread, each made with
`l4_factory_create_gate(factory, gate, service_thread, task_index << 2)`. The receive
gives the label, with the sender's rights in its low bits (`ipc_gate.cpp:504`), so
the decoder masks them and the rest names the calling task. A task can name only
itself, so a handle is always looked up in the caller's own table.

**The wire.** A request's tag has the call number as label and the argument words as
its count, in the UTCB's message registers. The stub and the decoder are generated
from the ABI file, as the `erx` backend's trap stubs are. Two backend-private
requests sit in a table of their own beside it: `reap(handle)` and
`add_utcb_page()`. A private word in the `erx_thread_create` and `erx_thread_start`
requests carries the semaphore's slot and the UTCB slot's address. The reply's first
word is the status, followed by the results.

**The loop.** `l4_ipc_wait`; decode; run the direct body, which takes the lock it
needs; `l4_ipc_reply_and_wait` with `L4_IPC_SEND_TIMEOUT_0`, so a caller killed during
a stop cannot hold the service. The root service makes no IPC to a task other than that
reply, and takes no lock a task can hold, so it cannot wait for a task.

**Refusals.** An unknown call number or a word count that differs from the ABI's is
`ERX_EINVAL`, and a call without a row is `ERX_ENOTSUP`. The decoder is a parser of
input from another task, and has a fuzz target. Addresses cross as values: the root
never loads through them, and it reaches a task's memory only through the pool window.

### Faults, and the fault of the root task

**One handler gate per task**, labelled the same way and bound to the handler thread,
is the `_pager` and `_exc_handler` of each thread in the task. The handler takes page
faults (`L4_PROTO_PAGE_FAULT`) and exceptions (`L4_PROTO_EXCEPTION`, with the
registers in the UTCB) in `l4_ipc_wait`, and never replies to one, because no fault
is repaired: every committed page is mapped already.

A fault message names the task, by the gate, and not the thread. A crash record's
thread field is `unknown`, and it carries the address and instruction pointer.

* **A test task's fault:** the record goes out through `erx_debug_log`, then
  `erx_space_stop(task, fault)`. The machine continues.
* **The root's fault:** the machine ends through [the end path](#the-end-path).
* **The handler's own fault** has no handler. Its pager is the `sigma0` gate and its
  fault repairs nothing, so the next fault of any thread hangs that thread, and the
  run ends by the watchdog or the harness's deadline. That is a recorded gap.

## The watchdog, the crash record and the console

### The watchdog

A root thread at the top priority runs `watchdog.c`'s step machine: sleep one period,
step over the pet word, which `erx_watchdog_pet` stores atomically. In deterministic
mode the step is off and the machine page says so. A missed pet takes the end path. A
kernel hang or a stall of this thread is not covered; the harness's deadline ends those
runs. K31 is Phase 2's.

### The end path

A fatal fault in the root, a missed pet and `erx_machine_end` all go through one
function. Any other thread may be anywhere, so it takes no lock.

1. **One caller.** An atomic exchange of the `ending` word; the loser sleeps forever.
2. **The sink.** The log sink becomes `l4_vcon_write`, by a flag it reads.
3. **Stop the writers.** `l4_task_delete_obj` on every thread in the root's table,
   except the caller, read with no lock since entries are only ever appended. When
   these return, none of them runs user code, which is what makes the console driver
   dead rather than merely unlikely to write. A lock a deleted thread held stays held,
   and this path never takes one.
4. **The record.** Undrained lines from the log ring, then the crash frame that
   [design-kernel.md](design-kernel.md) defines and `tools/lib/erx/crash_frame.rb`
   reads, both through `l4_vcon_write`.
5. **The end.** `l4_platform_ctl_system_shutdown(L4_BASE_ICU_CAP, 1)`. Under
   `-no-reboot` this ends QEMU.

### The console

**Kernel options.** Fiasco boots without `-serial_esc` and `-serial_input`, so
`Config::serial_input` stays `Serial_no_input` (`config.cpp:246,278-282`), and the
kernel never attaches the UART's receive line, which `Irq_chip_gen::attach` would
otherwise refuse the driver (`irq_chip_generic.cpp:77-81`). JDB is built out, so a
kernel panic halts and the harness's deadline ends the run. Nothing calls
`Vlog::get_input`.

**The handoff is one event.** Who writes is one pure C17 decision,
`erx_console_owner_step`, over two states, *kernel* and *driver*:

| Event | Step |
| --- | --- |
| before any event | the sink is `l4_vcon_write` on `L4_BASE_LOG_CAP`, the kernel's polled UART output; nothing reads the UART |
| `erx_mem_create_physical` of the manifest's console UART entry | under the log sink lock, so any `l4_vcon_write` in progress finishes, the sink becomes the log ring. Only then is the UART mapped and the handle returned |
| after it | the driver is the only reader, and, apart from Fiasco's own messages below, the only writer. `liberx`'s log goes to a ring of `log.c` records that the Erlang log reader drains to the console service |
| the end path | the driver has been deleted (step 3), and the sink is `l4_vcon_write` again |

So the driver's first touch of a register follows the last `l4_vcon_write`, by
construction, keyed on no time or flag a driver could race. A partial boot never maps
the entry, so its log lines reach the UART for the whole run, and the transcript tests
before M3 need no input.

Fiasco's own `WARN` lines and panic text can still reach the UART at any moment, and may
interleave with the driver's bytes. That is a recorded gap, not a thing to engineer
around. Text from a task passes the log's escape before either sink. Console behaviour
under TCG and HVF is unverified until the boot package runs.

## littlefs in the system domain

The design's placement is a sub-space port of the storage domain
([design-storage.md](design-storage.md)). Phase 1 has no storage domain and no
programs, and the seam the design names is the `erx_fs` callback module, so littlefs
runs in the system domain as a NIF behind that module. Its port form needs a task
launcher driven from Erlang, the channel protocol, `erx_program`, exit reporting and the
lane reader, about 4,000 lines by the plan's estimate, with no other Phase 1 consumer. The NIF needs
littlefs's C and about 500 lines of glue (unverified). When the port form lands, the glue
goes and the module's transport changes; the Erlang side stays.

A process running a dirty NIF cannot run its receive loop, so two processes share the
work:

* The **owner** takes clients' requests, one at a time as the design requires, and
  never blocks on the worker or on anything else.
* The **worker**, linked to it, alone calls the littlefs NIF, on a dirty I/O scheduler,
  one operation at a time.

**One block request**, from the callback littlefs calls on the dirty scheduler's thread:

1. The callback allocates a request: a NIF resource holding a state word, starting
   *pending*, and a buffer. For a write it copies littlefs's bytes into the buffer.
2. It posts `{block, Op, Block, Off, Len, Ref}` to the owner with `enif_send`, where
   `Ref` is the resource term. If `enif_send` reports the owner dead, it fails at once.
3. It waits with `erx_umtx_wait(&state, pending, deadline)`, in a loop.
4. The owner, a normal Erlang process on a normal scheduler, sends the request to the
   block driver and goes back to its receive. Writes go through the driver's one write
   path.
5. When the driver answers, the owner calls `complete(Ref, Result)`, an ordinary short
   NIF, which copies any read bytes into the resource's buffer, moves the state from
   *pending* to *done* by compare-and-swap, and calls `erx_umtx_wake`.
6. The callback, on *done*, copies a read's bytes from the resource's buffer into
   littlefs's and returns to littlefs.

**No dirty-scheduler deadlock.** Steps 4 and 5 and the device NIF run on normal
schedulers, and the driver's interrupts arrive by the dispatcher and the ready ring. One
operation holds one dirty thread, and nothing it waits for needs a second, so a single
dirty I/O scheduler is enough. The rules that keep this true: the owner makes no synchronous
call (the driver's answer is one more message); the owner and the driver use no file
operation on any volume, and no `logger` handler writes to `/data`; `complete` is not a
dirty NIF. A test runs with `+SDio 1`.

**Failure.**

* **A deadline.** It is longer than the block driver's restart. The callback moves the state
  from *pending* to *ended*, by compare-and-swap. If that loses to *done*, the request
  succeeded. If it wins, the callback returns `LFS_ERR_IO`, the operation fails, and its
  outcome is reported unknown, never made up.
* **A late `complete`** copies into the resource's buffer, which the term keeps alive and
  which littlefs does not read once the request has ended, and loses its compare-and-swap, so
  it does nothing.
* **The driver restarts.** The owner monitors it and resends what has no answer. Block reads
  and writes repeat harmlessly, so no acknowledged write is lost.
* **The owner dies.** Waiting callbacks end at their deadline, later ones at once by step 2,
  and the worker, linked, dies when its NIF returns. The supervisor starts a new pair, which
  mounts afresh. Each mount has its own littlefs state, and only an owner reaches the device,
  so the old worker cannot write.
* **A crash in littlefs's C** ends the system domain with a crash record.

## Deterministic mode

`erx.det=1` is one CPU, TCG with instruction counting, the interpreter. The harness runs QEMU
with `-smp 1` and `-icount sleep=off`. Fiasco boots on one CPU, with its tick from the
architecture's generic timer, which instruction counting makes a function of the instructions
executed. The backend's time page, deadlines and entropy derive from that counter and the
manifest's seed. ERTS runs one scheduler and the interpreter. The watchdog's step is off. The
comparison starts at erXos's banner. Whether Fiasco's own boot is deterministic under instruction
counting is unverified; if it is not, the comparison starts at the root's first line, recorded as
a stopgap difference, and the rule is not relaxed.

## What Phase 1 code must not assume

* **Handles are opaque.** They are not Fiasco capabilities, and not stable across a boot.
* **A committed page is present here, and Phase 2 populates lazily.** Code touches a page it
  committed; it does not read timing or fault counts from that.
* **One node today.** Local message delivery is Phase 1's transport and a frame on a lane is
  Phase 2's.
* **The device NIF keeps physical addresses behind the DMA profile**, and nothing else sees one.
* **Fiasco's exception messages stay in the backend.** Faults reach code as crash records.
* **Callers check `ERX_ENOTSUP`**, and show `unsupported` and `partial` as such.
* **No thread is destroyed from outside**, and no thread is stopped. ERTS's use of threads does
  not need either.

**A service's request interface is portable.** This is the rule for a service author:

> A service's request interface is the one its design document gives, whatever Phase 1
> enforces. A client reaches a service by a pid it was introduced to (the facet the domain
> library hands it at start, or the pid in a reply), never by a registered name of another
> application, `whereis`, or a module's `start_link` return kept across applications. A
> request and its reply carry portable terms only: atoms, numbers, binaries, lists, tuples,
> maps, pids and references; never a NIF resource, a fun, a port, an ETS table identifier, a
> `liberx` handle or a Fiasco value. A grant is named by the identifier the server issued for it
> and nothing else. A service reads no table, ETS or `persistent_term`, that another service
> owns. Local message delivery is Phase 1's transport and a frame on a lane is Phase 2's;
> neither appears in the request's shape. Then moving a service to another domain changes its
> introduction, not its callers.

The file namespace ([design-files.md](design-files.md)) and the shell's command context
([design-shell.md](design-shell.md)) are the two interfaces to follow first.

## What Phase 1 defers

Every guarantee of `design-kernel.md` (K1 to K33), `design-domains.md` (D1 to D17) and
`design-files.md` (F1 to F9). Phase 1 keeps a user-mode policy where the table says so;
everything else is a refusal or an unsupported value, and nothing is rebuilt in user mode.

| Family | Phase 1 | Lands |
| --- | --- | --- |
| K1, K2, K17, K21, K24, K25: generations, rights that only shrink, capabilities only in tables, release once, pass restrictions | a handle table in `liberx`; `erx_cap_pass` refused | Track K's pilot (the capability table), its conformance tests; hostile tests at M5 |
| K3, K32: every allocation charged, budgets as space banks, guarantees, caps, borrowing, walls, watch, resize | a page count per budget, reported partial | Track K's pilot (budgets); M5 (walls, "every charge returns"); M10 (users) |
| K4, K5, K6, K9: mapping ceilings, trimming never meets sharing, committed memory never faults, no translation outlives its access | eager mapping; a decommitted page faults to the handler | Track K (memory, the TLB planner), conformance tests |
| K7, K12, K13: no user address in the kernel, nothing panics the kernel, bounded kernel paths | nothing: Fiasco inherited | Track K; the hostile suites of M2, M5 and M11 |
| K8: no page writable and executable, JIT right from the image | `liberx` refuses write-plus-execute protections and `ERX_MEM_JIT` outside a JIT task; the manifest check keeps the root entry free of `ERX_IMAGE_JIT`; the root's pool window and image are read, write and execute | Track K (by construction in the kernel); M7 (the page-table walk); M11 |
| K10, K11, K15: no FP/SIMD in the kernel, FP state per thread, all processor state saved or trapped | Fiasco's own handling, inherited | Track K |
| K14, K20, K33: one CPU per thread and wake after switch-out, no upcall to an executor, waits hold nothing | Fiasco's scheduler; park in user mode | Track K; M2 (the executor rule, `ERX_EWOULDBLOCK`) |
| K16: the boot image immutable after validation | `bootstrap` validates; the root holds the image, trusted | Track K |
| K18, K26, K27, K28, K29, K30: stops, exit records, deletion at once, parents, fault gates, upcall events, holds | [task exit](#task-exit); faults end the task or the machine | Track K; M5 (exit records, `{domain_down, ...}`); Track K's after-the-switch increment (pauses); Track P (signals and upcalls) |
| K19, K31: the machine lease, the root's end and the kernel watchdog | a user-mode watchdog thread; a root fault ends the machine | Track K; M12 (the lease, the board watchdog) |
| K22, K23: copy-on-write children | refused | Track Q |
| groups: C0 to C2, quotas, cohorts, charging, park in the kernel, `erx_group_configure` enforced | a record; readiness only | M2; M8 (cooperation) |
| umtx in the kernel, across spaces | a per-task table | Track K |
| IPC gates with `ERX_EDEAD`, labels, deadlines, rendezvous passing, fault gates with no cross-domain waits | refused; Fiasco IPC inside the backend only | Track K; M5 (lanes, connections) |
| D1 to D7, D9: pids, node names, the funnel, no authority in a name, atom bounds, death reports, stopping without the runtime, signal order | one node; the funnel's own code runs hosted | M5 (the funnel's hardening, exports, introduction); M11 |
| D12, D13, D16, D17: peer-held memory bounded, stale exports cost nothing, connection pages owned and charged, a domain's end behind its last frame | no connections | M5; M11 |
| F1 to F5, F9: grant-rooted namespaces, no request above a grant's root, rearranging adds no authority, server admission, read-only grants, a program reaches files only through its handler | the system domain's namespace is local; servers accept every request; the request shapes are the design's ([the portable rule](#what-phase-1-code-must-not-assume)) | M5 (namespaces over connections, grants by introduction); Track S's programs (F9); M11 |
| F6, F7, F8: no write-plus-execute file grant, one copy of a file's bytes per session, shared mappings write back | no executables from files; no shared mappings | Track S's programs (F6); Track Q (F7, F8) |
| SH1, P2, command authority, pipe-end ownership, end of stream by holders | Erlang commands only | Track S's programs |
| devices: confined DMA, IOMMU windows, MSI, device-buffer lifetime, the device secret | unconfined DMA from the contiguous pool | M9; M11 (refused unless configured); M12 (the secret) |
| service CPU admission (facets, lanes, grants), inspection and crash-data authority | every service admits every local caller | M5, M8 (admission); M10 and M11 (authority) |
| the host link holding every facet | as designed for the stopgap | M10, M11 |
| entropy in the kernel; the kernel trace ring; deterministic mode at the kernel's level; one route from user mode; every kernel chokepoint; the kernel stack proof | `rng.c` in user mode; a user-mode trace ring; [the recipe](#deterministic-mode); none | Track K |
| the hostile suites and the security closure | none | Track K's first part (the call-level hostile domains); M2, M5, M9, M11 |
| the startup proof: `erx_root_plan` run by the packer and the kernel, and its charge evidence | [the root startup rule](#the-phase-1-manifest-check) | Track K's first part, before GK3 |
| the manifest's properties outside Phase 1's scope | [refused records](#the-phase-1-manifest-check) | M5, M9, M11 |

Not in Phase 1, since they come with toybox and Track S's programs, so nothing here serves them:
executables loaded from files, with their supply, seal and install path; signals and
`erx_vcpu_control`, `erx_vcpu_resume`; pipes between programs; the startup message; the channel
protocol.

## Verification

Each increment is a QEMU transcript test under TCG and HVF, one and four CPUs, kept in the suite.
Each case below is paired with a seeded failure, applied as a test-only patch, that makes the case
fail, which proves the case ran the code it claims to.

| Case | Seeded failure, and what it shows |
| --- | --- |
| **Boot.** One line through `l4_vcon_write`, then shutdown; the banner lines in order | shutdown call removed: the harness's deadline fires. A damaged archive entry: `bootstrap` stops with the check's reason |
| **Self-map and raise**, first in the memory package: commit, write, raise from R to RW in the root | map from the wrong window page: contents differ |
| Commit, write, decommit, recommit, read zeros | zeroing skipped: old bytes read |
| Write, protect to no access and back, read the same contents | protect takes a fresh page instead of the same window page: zeros read |
| RW to RX and back on a page holding code, run it each time, then a write in the RX state, in a test task whose fault the harness expects | the drop step skipped: Fiasco adds rights, so the write succeeds and the expected fault is missing |
| A stack through `PROT_NONE` then RW works | commit on access change removed: fault to the handler |
| A refused protect, with the pool short, changes nothing | plan applied page by page: the first page's protection has changed |
| Touch a decommitted page: crash record and shutdown, the pool's count printed before | handler skipped: the cause line is missing |
| **Range table, host tests**, exhaustive over page states and target protections | a target with write and execute admitted: the test fails |
| **Thread start**: TLS read in the new thread equals the value given | trampoline does not set the thread pointer: value differs |
| **Timed umtx wait** times out at its deadline and no earlier | deadline rounded down: the counter check shows it early |
| **Umtx host model and TSan**: a wake between compare and sleep, a timeout racing a wake | compare outside the lock: the model finds a lost wake. Absorb removed: the next wait returns at once with a stale count, and the model fails |
| **Join loop, 10,000 times**: stack and slot reused; after each join, `erx_object_info` on the joined thread's handle is stale | reaper's steps 1 and 3 swapped: the joiner sees a live handle. Step 3 removed: the joiner hangs and the deadline fires |
| **Slot reuse**: each new thread checks that its own marker reads 1 during its whole life | the claim ignores the marker: under the loop, Fiasco's late write of 0 lands on a live thread and the check fails |
| **Detached loop**: the range and the slot return; the pool's count is steady | range omitted from the record: the count falls each iteration |
| `pthread_cond_broadcast` with 64 waiters, all proceed; one mutex held at a time | the next waiter's barrier left locked: the deadline fires |
| **Park state machine**, exhaustive host test: every order of two executors, two objects and three events, asserting no state with work ready, a slot parked and no up owed | the park's epoch comparison removed: a lost wake is found. An up to a slot still listed: a stale count is found |
| **Park on QEMU**: a trigger between the empty check and the park, by a test hook | the hook is removed: the case's count of immediate returns is 0 and it fails |
| Affinity to each CPU, read back from where the thread runs | mask ignored: a thread reports the wrong CPU |
| **A second task**: built from a boot-image program, commits memory and creates a thread through the service, runs code through the read-execute alias of a JIT object | cache maintenance skipped: under HVF the alias runs stale code. RW alias mapped RX: the write faults |
| **Task exit**: a thread of the task spins, counting on a shared page; after the stop the count is frozen; the pool's count returns to its value before the task | step 2 skipped: the count moves or the pool is short. Step 4 skipped: the pool is short |
| **Task fault**: the task's record appears, and the machine continues | the handler ends the machine instead: the following line is missing |
| **An interrupt**: a UART receive and a software object, bound with labels; a parked executor wakes; `erx_group_take_ready` returns each label once; ack lets the next through | ack removed: the second character never arrives. Listed flag ignored: a label twice |
| **Trace ring**: `erx:trace` shows a park, a wake and an IRQ delivery in order; the kernel's row shows `unsupported` | the dispatcher's write removed: the delivery is missing from the timeline |
| **Watchdog**: a stopped pet ends the machine, with its cause in the record | watchdog skipped: the deadline fires instead |
| **End path**: a fault while a test driver floods the UART; the crash frame parses whole | step 3 skipped: driver bytes interleave and `crash_frame.rb` reports it truncated |
| **Console handoff**: log lines before and after the UART's create, each reaching the console once and in order | sink switched after the map: a counter of `l4_vcon_write` calls after the create is nonzero. Host test of `erx_console_owner_step`, with a carve of another entry changing nothing |
| **littlefs**: a file operation under `+SDio 1` with a block read in the callback completes | `complete` made a dirty NIF: the deadline fires, which is the deadlock this design avoids |
| littlefs: a block error injected mid-write fails that operation with the outcome reported unknown, and no acknowledged write is lost | the error swallowed: the operation claims success |
| littlefs: block driver restarted under load; a file synced under `/data` survives a power cut at each step | resend removed: operations time out. Sync skipped: the file is lost |
| **Manifest check**: each kept property with a seeded violation, each refusal with a seeded record | the table in [the manifest check](#the-phase-1-manifest-check) is the pairing |
| **Root service decoder**: fuzz target, and a task sending an unknown number and a wrong count | word-count check removed: the fuzz target reports the over-read |
| **Chokepoint**: a Fiasco header outside the backend | the seeded violation is itself the case |
| **Function-API set**, on hosted and Fiasco backends alike, refusals included; `make check-reproducible` on the production image | a refusal changed in one backend: the shared set fails |

Host tests and TSan models run the pure cores: the range table, `park_step`, the umtx table,
`erx_console_owner_step`. M7's parity gate runs the `erx` backend differentially against this one
over the test corpus.

## Differences from erXos's kernel

The table M7's parity review works from. Each row is a call or family where the two backends
differ in behaviour a caller could see. A difference not listed is a bug in the replacement, or in
this one.

### Transport

The function API is the seam. The `erx` backend's generated stubs trap into the kernel with the
registers of `abi/arch/<arch>.txt`. Here the same functions run direct bodies in the root, and call
the root service in a task, or run locally. So no call number or register reaches a caller, and
everything above `liberx` is unchanged.

| Call or family | erXos's kernel | This backend |
| --- | --- | --- |
| `erx_vm_commit` | lazy population with committed memory reserved (K6) | eager |
| `erx_space_protect` | moves beneath a ceiling (K4) | policy in `liberx`; the root's pool window is read, write and execute |
| `erx_mem_create` and `erx_vm_map` | any kind and count, within rights | shared objects and physical objects once; grow and seal refused |
| `erx_mem_dma_addr` | through a window (M9) | physical address, unconfined |
| `erx_irq_trigger`, `erx_irq_ack` | by capability, from any holder | through the root from a task; no IRQ object leaves the root |
| `erx_irq_route` | applied | recorded, not applied |
| `erx_group_configure`, `erx_group_info` | grants enforced, usage reported | recorded; usage `unsupported` |
| `erx_park`, `erx_executor_wake` | in the kernel, the executor switched | in user mode, on a semaphore; no CPU placement |
| `erx_umtx_*` | across spaces; `ERX_EFAULT`, `ERX_ESTALE`, `ERX_EINTR` | per task; a bad address is a fault |
| `erx_thread_create` | backed and charged before it returns | the UTCB is bound at start |
| `erx_thread_stop`, `_read`, `_write`, `_set_urgency` | supported | `ERX_ENOTSUP` |
| `erx_object_destroy` on a thread | ends it at once | `ERX_ENOTSUP` for a started thread, except its reaper |
| `erx_space_stop` | exit record, parents, kernel-side quiesce | [task exit](#task-exit), a status to the launcher |
| `erx_space_create` | parents and fault gates enforced | recorded |
| `erx_budget_*`, `erx_object_info` on a budget | exact, all fields | `used` partial; the rest `unsupported`; resize and watch refused |
| capabilities | generations, rights, transfer at rendezvous | handles in a table; `erx_cap_pass` refused |
| IPC gates, messages, lanes, paged objects, `erx_vcpu_*`, `erx_mem_copy`, `erx_mem_child` | supported | `ERX_ENOTSUP` |
| watchdog and machine end | in the kernel (K31) | a user-mode thread |
| entropy | in the kernel | `rng.c` in user mode, `quality: low` |
| fault of a thread | to the fault gate, with its identity | crash record; thread `unknown` |

## Read in source, never run

Each of these has been read in the cited lines and has not been executed. The first packages run
them, and any that fails changes this document.

| Claim | Where read | Settled by |
| --- | --- | --- |
| `l4_task_map` accepts the root as both sender and receiver, and a second map raises rights | `lock_guard.cpp:245-256`, `mapdb.cpp` `lookup_src_dst`, `map_util.cpp:640-660,715-770`, `mem_space-arm.cpp:241-270` | the memory package's first test. Fallback in [Protection](#protection) |
| A window superpage serves as parent of page mappings, and unmapping a child leaves it | `map_util.cpp`, `to_fit_size` loop | same test |
| A return from `l4_task_delete_obj` on a thread means it never reaches user mode again | `thread.cpp:657-690`, `thread_object.cpp:157-166`, `kobject.cpp:224-233` | the join loop |
| `free_marker` goes to 0 only after the kernel has finished with the UTCB | `thread.cpp:603-604`, `utcb.h:176-185` | the slot-reuse case |
| An unbound thread that never started can be deleted | `thread_object.cpp:161-164`; L4Re's error path deletes one (`manager.cc`) | a create, destroy case |
| The semaphore object comes from `l4_factory_create` and is built into near-stock Fiasco | `factory.h:470`, `semaphore.cpp:329`, `l4_types.cpp:458` | the thread package |
| The ICU capability is the platform control object, and shutdown through it works on QEMU `virt` | `platform_control_object.cpp:9,31`, `irq_controller.cpp:76` | the boot package |
| `Region::Root` regions reach `sigma0` as bootloader memory for the root, at the rights their sub-type gives | `init_kip.cc:80-82`, `init_mem.cc:71-77`, `boot_modules.cc:103` | the boot package |
| `l4sys` links against freestanding musl; its syscall object is external assembly, not header-only (`ipc.h:25-26`) | the header | the boot package |
| Configuration names for no serial input and no JDB | `koptions-def.h`, `config.cpp:278-282`; the build configuration not read | the boot package |
| Console behaviour under TCG and HVF, and Fiasco's messages interleaving with the driver | `vlog.cpp`, `irq_chip_generic.cpp:77-81` | the boot package and M3 |
| Fiasco's boot is deterministic under instruction counting (medium confidence: its delay calibration and timer setup are unread) | not read | the deterministic transcript |
| RCU grace periods proceed while threads spin and yield on the root lock | `kobject.cpp:224-233`, `thread.cpp:479-489` | the task exit test on four CPUs |
| `enif_send` from a dirty NIF's callback, and its report of a dead receiver | `erl_nif.c` not read past `:443` | the littlefs case |
| The size estimates: backend packages 1 to 6, 3,000 to 4,500 lines of C17; the musl port 1,000 to 2,000; NIF glue about 500 | estimates | the packages |
| `l4_task_unmap` of the write or execute right alone leaves the mapping and its other rights; `L4_FP_OTHER_SPACES` on a window page removes every derived mapping and keeps the window's | `task.h:101-135` and `consts.h:200-222` only; `fpage_unmap`'s memory path not read | the protect cases, the JIT object's destroy |
| A bound line stays masked from delivery until `l4_irq_unmask`; a software trigger arrives at the dispatcher as a message with the bound label | `irq.h` declarations only; `irq.cpp`'s delivery not read | the interrupt package |
| A bound thread's fault blocks it until it is deleted, when the handler never replies | `thread.cpp:582-584` (`reset_reply_cap`), the fault paths not read | the task fault case |
| Musl's `tid` being used for anything beyond `__tl_lock` and mutex ownership (`__synccall`, `pthread_kill` need signals, which Phase 1 lacks) | `pthread_mutex_trylock.c:8-12`, `pthread_create.c:30-40` | the musl port, `libc-test` |

## Open decisions

1. **Where littlefs's protocol lives.** It is here because every step of it rests on this backend,
   and because it disappears with the port form. The alternative is `design-storage.md`'s read-write
   storage section, which owns the seam. Recommendation: keep the protocol here while Phase 1 lasts,
   and have `design-storage.md` state the placement and link to it, since its target text describes the
   port form.
</content>
