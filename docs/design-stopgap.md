# The Phase 1 backend

Phase 1's kernel is Fiasco, near stock, imported under `fiasco/`. `liberx/backend/fiasco`
implements erXos's calls on it, in user mode. This backend is the current implementation behind an
interface erXos owns: the generated C functions of
[design-runtime.md](design-runtime.md#the-liberx-interface), defined by
[design-kernel.md](design-kernel.md). At M7 the `erx` backend replaces it and nothing above
`liberx` moves.

Three constructions carry the document:

* **One owner, one thread.** The root task holds every Fiasco capability and every page, and one
  thread of it, the root service, alone touches the tables that record them. Every other thread,
  the root's included, sends it a request or a fault and waits. So the root's tables need no lock,
  a request cannot overlap its task's exit, and ending a task is a list one thread walks.
* **One page, one address.** Each page of RAM has one permanent address in the root's pool window.
  Every mapping derives from it, so a mapping can come and go while the page and its contents stay,
  and the root reaches any task's memory without mapping anything.
* **One index per thread.** A task has a fixed table of 128 threads, made with the task. An index
  names a record, a public UTCB, a native UTCB slot and musl's thread identifier.

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

* **It promises**, for trusted workloads: the results in [the call table](#the-call-table), no
  memory errors, no deadlock, and exact accounting of whatever it reports.
* **It refuses** a call with no Phase 1 consumer with `ERX_ENOTSUP`, which every caller checks.
* **It reports as unknown** what only a kernel could know: `unsupported`, or `partial` with its
  reporter and scope, never a made-up number.
* **It does not promise** what [What Phase 1 defers](#what-phase-1-defers) lists, with each known
  gap in one line.
* **It contains** only mechanisms with a Phase 1 consumer and stored fields with a reader, in
  L4Re's shapes wherever L4Re has one.

[Read in source, never run](#read-in-source-never-run) lists what the first packages must check; a
claim that fails changes this document.

## Ownership and authority

Everything above `liberx` calls the generated functions. Each has one stub, in every image, the
root's included. The stub runs locally, for calls that never need the kernel, or sends a request to
the [root service](#the-root-service), which runs the call's body.

### Capabilities in Fiasco's object space

The root holds a capability to every object it creates, with Fiasco's delete right, so
`l4_task_delete_obj` always reaches it. Callers hold **handles**: indices in a per-task handle
table the service keeps, never Fiasco capability values. Another task holds only these, mapped by
the root with `l4_task_map` and rights `L4_CAP_FPAGE_RWS`:

| Slot | Object | Used for |
| --- | --- | --- |
| `L4_BASE_PAGER_CAP` | the task's gate | `_pager` and `_exc_handler` of its threads, resolved in the thread's own task at the fault (`thread-ipc.cpp:254,1020`), and every request |
| the first slot after `L4_BASE_CAPS_LAST`, plus the thread's index | the thread's semaphore | umtx, park, reaper |

The time page, status pages and boot information page are mappings, not capabilities.

### Helper threads

Each is backend C with no thread-local storage, and calls no musl function.

| Thread | Runs in | Does | Phase 1 consumer |
| --- | --- | --- | --- |
| root service | root | owns the root's tables; serves requests, page faults and exceptions | every call and crash record |
| watchdog | root | steps `watchdog.c` over the pet word | M3's criteria |
| reaper | each task, one | deletes exited threads ([Deletion](#deletion)) | `pthread_join`, detached threads |
| dispatcher | the group's task, one per group | turns IRQ deliveries into triggers | console and block drivers, ERTS's wakes |

A task's own threads create its reaper, at backend initialisation, and its dispatchers, at group
creation, through the ordinary calls. `moe`, L4Re's root task, is likewise one server thread for
memory and faults (upstream; `moe` is not in this tree), and `libpthread` serializes thread and UTCB
work through one manager thread (`manager.cc:494`). The cost is that the machine's memory, thread
and log calls queue on one thread, which Phase 1 accepts and an ERTS boot measures.

### Locks

All are spinlocks whose failed attempt calls `l4_thread_yield`. None is held across a Fiasco call
or a request, and no thread holds two. A wake or `l4_semaphore_up` follows the unlock.

| Lock | Scope | Guards |
| --- | --- | --- |
| thread lock | one per task | the records' free states, the reaper's list |
| umtx lock | one per task | the umtx table |
| park lock | one per group | a group's epochs, parked list, ready ring |
| trace lock | root | [the trace ring](#the-trace-ring) |

The service takes only the trace lock, and otherwise waits only on Fiasco's calls and `sigma0`.

### The chokepoint

Fiasco's headers and capability values appear only under `liberx/backend/fiasco`. A build check
fails on a new site, and has a seeded violation.

## Boot handoff

**Bootstrap.** `bootstrap` is the first stage of the bootable file
([design-kernel.md](design-kernel.md#the-bootable-file)). `startup()` calls `erx_image_load`
(`erx_image.cc`), which applies one pure plan, `erx_boot_load_plan` (`kernel/core/boot_place.c`).
Inherited code reads no executable and no modules.

1. The plan finds the archive through the locator in the bootable file's header, or as the one
   initrd, opens it with `erx_pack_open`, and checks each role's file with `erx_pack_file_check`:
   the kernel at `boot_kernel_path`, `sigma0` at `boot_sigma0_path`, and the root at
   `boot_stand_in_root_path`, the path at which the packer stores the system release's root entry.
2. It reads each with `erx_elf_plan_kernel` and chooses where it goes. An image that relocates
   itself, as the fork's kernel and `sigma0` do, goes behind the archive, and a kernel that cannot
   relocate fails the plan. The root, a static executable, runs at the physical addresses it is
   linked at, which must clear the archive, `bootstrap`, the device tree and every reserved
   region. A refusal prints `erXos image: <where>: <reason>` and stops, having copied nothing.
3. `apply` reserves the whole archive first, unmoved and never released, then the images, then
   copies. The archive so reaches `init_kip_md` whole. A `Region::Root` region's sub-type is what
   `sigma0` may page to the root (`init_mem.cc:73`): `Root_section_rwx` for the root's image,
   whose segments one range cannot tell apart, and `Root_section_ro` for the archive.
4. `erx_boot_handoff_write` writes the `erx_boot_handoff` record of `abi/kernel.txt` (flags, build
   identifier, index hash, the archive's range, and `/chosen/bootargs` cut at the last whole word)
   into the options block for the kernel. That block is mapped into no task, so it also writes the
   record into the **handoff page**, a free page from `mem_manager->find_free_ram`, reserved as
   `Region::Root` with `Root_section_ro`. The record's pool fields stay zero, with no reader.
5. `init_kip_infos` assigns the page's address to the kernel information page's `user_ptr`
   (`init_kip.cc:30`), which `boot_info_t` carries there.

**The kernel.** Its options are a constant, `Fiasco::KERNEL_OPTIONS` (`fiasco.rb:67`), built into
`bootstrap`, with neither `-serial_esc` nor `-serial_input`, and it is built without JDB. Its own
changes are `erx_handoff.cpp`: it accepts the record, prints the banner (`development build: trusted
code only`, the build identifier, the index hash) and panics if no bootloader descriptor covers the
archive. The fork's kernel-call route, `erx_probe` and `erx_syscall`, is out of its build
(`Modules.generic:112`). It starts `sigma0` and then the root (`std_workload.cpp`), with capabilities
at `L4_BASE_TASK_CAP`, `L4_BASE_FACTORY_CAP`, `L4_BASE_THREAD_CAP`, `L4_BASE_PAGER_CAP` (a gate to
`sigma0`), `L4_BASE_LOG_CAP`, `L4_BASE_ICU_CAP` (also the platform control object) and
`L4_BASE_SCHEDULER_CAP`; a stack pointer of 0; one page of UTCB slots (`std_workload.cpp:95`);
Fiasco's default priority, on the boot CPU.

**The root's first steps, in order.** Only the first thread exists until step 7, so it runs the
service's bodies directly.

1. Sets its stack, inside its image. Touching it faults to `sigma0`, which maps it one to one.
2. Maps the kernel information page with `l4sigma0_map_kip`, and from `user_ptr` the handoff page,
   and accepts the record with `erx_boot_handoff_accept`.
3. Maps its whole image, and the archive read-only, at their physical addresses with
   `l4sigma0_map_mem`. After this step no page of the root is mapped on demand.
4. Reads the manifest through its generated C reader, which allocates nothing. Later steps take
   device entries, wall offset, seed and watchdog period from it.
5. Builds the pool window and contiguous pools ([The pool](#the-pool)).
6. Makes its own thread table ([Thread creation](#thread-creation)); fills the time page; seeds
   `rng.c`; writes its boot information page, flagged `ERX_BOOT_ROOT`; creates its gate, the service
   thread, stopped, with the `sigma0` gate as pager, and the watchdog with its configuration and start
   event (`watchdog.c:127`).
7. Points its own `_pager` and `_exc_handler` at its gate and runs the service and the watchdog.
   **From here the service alone touches the root's tables.**
8. Creates its reaper and enters musl's start path, which runs ERTS.

A failure in steps 1 to 6 prints its reason through `l4_vcon_write` and ends the machine, with no
crash record.

**Boot information.** The ABI's `erx_boot_info` layout is kept. `budget`, `space`, `group`,
`group_ctl`, `group_stat`, `time_page` and `release` hold handles. `crash_area` and
`system_connection` hold zero. The launcher writes a test task's page the same way and maps it
read-only.

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

Every consumer kept in Phase 1 has a row, and `ERX_ENOTSUP` answers everything else. This one table
lists calls, refusals and differences. M7's parity review works from its last column: a difference
not listed is a bug in one backend. "Service" and "local" say where the body runs. The hosted
backend gives the same rows and refusals (Track H), and both pass one function-API test set, which
seeds Track K's conformance roster.

| erXos call | Phase 1 consumer | Body | Result and refusals | erXos's kernel instead |
| --- | --- | --- | --- | --- |
| `erx_vm_reserve`, `_commit`, `_decommit`, `_release`, `erx_space_protect` | musl `malloc`, ERTS allocators, stacks | service: [Budgets](#budgets-and-the-ownership-of-pages) | correct contents; `ERX_ENOMEM` from the pool; write and execute together `ERX_EINVAL`; a touch of a decommitted page is a fault | lazy population with committed memory reserved (K6); protection beneath a ceiling (K4) |
| `erx_mem_create`, `erx_vm_map` | BeamAsm's JIT object in its test task; the time page, a group's areas | service: pool pages recorded as an object; each map is `l4_task_map` from the window. `ERX_MEM_JIT` only from a task made with `ERX_SPACE_JIT` | any number of mappings; `erx_mem_grow`, sealing `ERX_ENOTSUP` | grow and seal work |
| cache maintenance, the code barrier | BeamAsm | local: asmjit's and ERTS's sequences unchanged ([design-arch-aarch64.md](design-arch-aarch64.md)) | correct | none |
| `erx_mem_create_physical` | the device NIF: UART (M3), virtio-mmio block (M6) | service: `l4sigma0_map_iomem` into the root at a reserved address, from the manifest's device entry; for the console UART also [the handoff](#the-console) | a second `erx_vm_map` `ERX_ENOTSUP` | any count, within rights |
| `erx_mem_create_contiguous`, `erx_mem_dma_addr` | the device NIF's buffers and rings (M6) | service: first fit from a [contiguous pool](#the-pool), aligned to its size rounded up to a power of two, at most 1 MiB, cached. `dma_addr` is physical address plus offset | unconfined; `erx_dma_map`, windows `ERX_ENOTSUP` | through a DMA window (M9) |
| `erx_irq_create`, `erx_irq_bind`, `erx_irq_ack`, `erx_irq_trigger` | console (M3), block (M6), `{erx_irq, Device, Line}` sinks; ERTS's wakes | service: `l4_factory_create_irq` and, for a line, `l4_icu_bind`; `l4_rcv_ep_bind_thread(irq, dispatcher, record)`; `l4_irq_unmask`; `l4_irq_trigger` | each label once, the line masked until acked; `erx_irq_route` `ERX_ENOTSUP` | by capability, without the root; route applied |
| `erx_group_create`, `_configure`, `_info`, `_take_ready` | the adapter's five changes (M3) | local: [Interrupts and readiness](#interrupts-and-readiness). `configure` keeps only the CPU set, which `info` reports as capacity | correct readiness; everything else `unsupported`; no guarantee, quota or throttling | grants enforced, usage reported |
| `erx_park`, `erx_executor_wake`, `erx_yield` | ERTS's schedulers (M3) | local: [The park protocol](#the-park-protocol); `l4_thread_yield` | no lost wake; a worker `ERX_ETYPE` | in the kernel, the executor switched |
| `erx_umtx_wait`, `erx_umtx_wake` | musl's futexes | local: [The umtx table](#the-umtx-table) | correct within a task | across spaces; `ERX_EFAULT`, `ERX_ESTALE`, `ERX_EINTR` |
| `erx_thread_create`, `_start`, `_exit`, `_set_affinity` | `pthread_create`, ERTS's threads, `libc-test` | [Thread creation](#thread-creation), [Deletion](#deletion); affinity is `l4_scheduler_run_thread` | no free index `ERX_ENOMEM`; `erx_thread_stop`, `_read`, `_write`, `_set_urgency` `ERX_ENOTSUP` | backed and charged at create; those calls work |
| `erx_space_create`, `erx_space_stop`, `erx_image_map` | the test-task launcher in the root (`libc-test` M3, BeamAsm M4) | service: `l4_factory_create_task`; segments through `elf_plan.c`, copied through the window, cleaned and invalidated, mapped code read-execute and data read-write; [task exit](#task-exit). `parent`, `fault`, `label` ignored | a "domain" is a task with no budget, grant, lanes, facets or exit record; `erx_space_pause`, `_resume`, `_clear_caps`, `_quiesce`, `_copy` `ERX_ENOTSUP` | parents, fault gates, exit records, quiesce |
| `erx_cap_dup`, `erx_cap_close`, `erx_object_destroy`, `erx_object_info` | Erlang NIF handles, the launcher | service: the handle table; destroy deletes the Fiasco objects, and for memory revokes every mapping first | destroying a started thread, `erx_cap_pass` `ERX_ENOTSUP` | generations, rights, transfer at rendezvous; a thread ends at once |
| `erx_budget_create`, `_resize`, `_watch` | the domain library's root entry (M3), the inspector | service: [Reporting a budget](#reporting-a-budget) | `used` partial, the rest `unsupported`; resize, watch `ERX_ENOTSUP` | exact, all fields |
| the time page, `erx_time_set_wall` | ERTS's time, deadlines | service fills a page mapped read-only into every task: the scale of the architecture's user-readable counter, the wall offset; reading is local | correct layout | none |
| `erx_entropy_read`, `erx_entropy_add` | ERTS's `crypto` seed, the host link | service: `rng.c`, from the counter and the manifest's seed | `quality: low` in the banner | in the kernel |
| `erx_debug_log`, `erx_log_read` | `liberx`, ERTS's crash path, test tasks; the Erlang log reader | service: [The console](#the-console) | correct | in the kernel |
| `erx_watchdog_pet`, the crash record, `erx_machine_end(res, how)` | M3's criteria | pet: a local atomic store in the root, `ERX_ENOTSUP` in a task. End: [The end path](#the-end-path) | correct, except a kernel hang or a stalled watchdog | in the kernel (K19, K31) |
| a thread's fault | a test task's fault | [Faults](#faults-and-the-fault-of-the-root-task) | crash record, thread `unknown`; ends the task, or the machine for the root | to the fault gate, with the thread's identity |
| IPC gates, messages, lanes, `erx_mem_copy`, `erx_mem_child`, paged objects, `erx_vcpu_*` | none | none | `ERX_ENOTSUP` | supported |

## Budgets and the ownership of pages

All of this runs on the service, so a page's state changes one call at a time.

### The pool

At boot the root takes all RAM from `sigma0` with `l4sigma0_map_anypage(pager, window_cursor, order,
&phys, order)`: first one 2 MiB superpage for each **contiguous pool** the manifest's device entries
ask for, recording `phys`; then everything else, at 2 MiB until refused and then 4 KiB until refused.
`sigma0` maps RAM read, write and execute (`memmap.cc:96,125`). QEMU `virt` is coherent, so cached
memory serves for devices.

The window starts at a constant of the backend's address layout, above all RAM, and is never unmapped.
**A page's identity is its window address.** Only a contiguous pool records a physical address. Free
pages are a list threaded through the pages, and a page is zeroed when taken. An exhausted pool is
`ERX_ENOMEM`.

### The range table

One table per task, a pure core that builds for the host and returns plans. Each record is a reserved
range, whose pages are each *uncommitted* or *committed* with a window address, with a protection. Each
mapping of a shared object has its own record. A call computes a whole plan (take-page, zero, map and
unmap steps, and the pages needed), refuses it if the pool cannot cover it, and only then applies it, so
a refused call changes nothing.

* **Commit:** take a page, zero it, and `l4_task_map(task, L4_BASE_TASK_CAP, l4_fpage(window,
  L4_PAGESHIFT, prot), l4_map_control(addr, 0, 0))`. A committed page is present.
* **Decommit:** `l4_task_unmap(task, l4_fpage(addr, L4_PAGESHIFT, L4_FPAGE_RWX), L4_FP_ALL_SPACES)`, and
  the page returns to the pool.
* **Release:** decommit what is committed, drop the record.
* **Revoke** (destroying a shared object): `l4_task_unmap(L4_BASE_TASK_CAP, l4_fpage(window, L4_PAGESHIFT,
  L4_FPAGE_RWX), L4_FP_OTHER_SPACES)`, which removes every derived mapping and keeps the window's, then
  the pages return to the pool.

### Protection

`erx_space_protect` works on the page's record, so it cannot lose contents. Dropping a right is
`l4_task_unmap` with that right. Raising is `l4_task_map` of the same window page at the same address,
which **adds rights and never replaces them** (`map_util.cpp:643`, `mem_space-arm.cpp:241`) and invalidates
no entry when the memory type stays (`page-arm.cpp`, `is_attribs_upgrade_safe`). So a change in both
directions drops first. Write means read and write, execute means read and execute.

| From | To | Steps, in this order |
| --- | --- | --- |
| uncommitted | no access | record only |
| uncommitted | R, RW or RX | take a page, zero it, map it with the target: K4's commit on access change, and musl's guarded stack (`pthread_create.c:295-297`) |
| no access, or R | R, RW or RX | map the same window page with the target |
| RW or RX | R | unmap the write or the execute right |
| RW | RX | unmap write, then map RX |
| RX | RW | unmap execute, then map RW |
| any | no access | unmap all rights; the page stays committed, its contents kept |

Pages change in ascending address order. A thread touching a page against the change faults, which is its
own bug, as it raced its own `mprotect`.

**The root as sender and receiver.** The root's own ranges use the same call, with `L4_BASE_TASK_CAP` as both
destination and source (`lock_guard.cpp:255`). If Fiasco refuses it, they map from `sigma0` with
`l4sigma0_map_mem`, keeping each page's physical address, and tasks keep the window path.

### Shared objects and the JIT alias

A shared object is an array of window addresses, and `erx_vm_map` maps each page with the requested rights, so a
read-write alias and a read-execute alias are two mappings of one window page. No task's mapping has write and
execute at once. The pool window itself does, in the root, so M4 checks the range table and tests each JIT alias
by a fault, and the page-table walk belongs to M7.

### Reporting a budget

A budget counts the pages the pool handed out under it. `erx_object_info` reports `used` as **partial**,
reporter `liberx pool`, scope "pages committed through `liberx`; not kernel objects, page tables or mapping
records". `guarantee`, `cap`, `carved`, `lent` and `pinned` are `unsupported`.

### Kernel memory and the root budget

Fiasco's objects, page tables and mapping records come from its own allocator, sized at boot, charged to nothing
erXos can see. A call that fails for lack of it is `ERX_ENOMEM`; exhaustion on a path that cannot fail is inherited.

## Threads, waits and exit

### Scheduling

Fiasco's fixed-priority scheduler schedules every thread; ERTS schedules its processes within them. Every thread
but the watchdog runs at Fiasco's default priority of 1, as the root's first thread and `sigma0` do, so a spinner
never outranks a preempted lock holder on its CPU. The watchdog, which takes no lock, runs at 255.
`l4_scheduler_run_thread(L4_BASE_SCHEDULER_CAP, thread, &param)` starts each thread, with `param` from
`l4_sched_param(priority, 0)` and the CPU mask in `param.affinity`.

### Thread creation

**The thread table.** Made with the task: 128 **records** of 2 KiB, in 64 committed pages at a constant address,
whose window addresses the service keeps. A record starts with the thread's public UTCB
([Transport](#transport)), followed by the starting registers, a free or used state, the semaphore's slot, the
group slot, the word to clear, the range to release and the umtx node.

The same indices own 128 native UTCB slots of 1 KiB, the most one Fiasco area holds (`task.cpp:356`), zeroed by
Fiasco (`task.cpp:253`). `l4_factory_create_task`'s `utcb_area` makes them for a task, and one
`l4_task_add_ku_mem` for the root, whose first thread keeps its kernel-given slot as index 0.

**Claiming an index.** Fiasco writes `free_marker` when finished with a UTCB, in `do_kill`, some time after the
deletion call returns (`thread.cpp:603-604`, `utcb.h:176-185`). So an index is claimable when **its record is
free and its marker reads 0**, checked under the thread lock, lowest first, as L4Re checks (`manager.cc:541`).
Only `erx_thread_start` and the trampoline set a marker, and only Fiasco clears one. No claimable index is
`ERX_ENOMEM`.

**`erx_thread_create`.** The stub claims an index. The service runs `l4_factory_create_thread` and
`l4_factory_create(factory, L4_PROTO_SEMAPHORE, cap)` (`factory.h:470`, `semaphore.cpp:329`), maps the semaphore
at the index's slot, copies the starting registers from the caller's public UTCB into the record, and replies
with the handle and the slot, which in the root is the root's own capability. On failure the stub frees the
record and returns `ERX_ENOMEM`. A task names only itself as the space; the root may also name a task with no
thread yet, which takes index 0.

**`erx_thread_start`.** The stub writes the marker 1. The service, in order:

1. `l4_thread_control_start`, `_pager` and `_exc_handler` naming the task's gate, `_bind(slot, task)`, `_commit`.
2. `l4_thread_ex_regs(thread, trampoline, record, 0)`.
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
root cannot reach a task's native UTCB, sets the stack, thread pointer and argument from the starting registers,
and jumps to the entry.

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

A deadline is absolute monotonic nanoseconds. The backend reads the time page, takes the remainder, rounds it up to
microseconds and passes `l4_timeout_from_us`, which rounds up again (`__timeout.h:292`), as the receive timeout. So a
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
4. **Recycle.** Mark the record free.

**Join: musl's code stays.** The word to clear is `&__thread_list_lock`, the contract of Linux's exit futex address
(`pthread_create.c:142-146`). `__pthread_exit` holds `__tl_lock`, sets `self->tid` to 0 and unlinks itself, leaving the
lock word holding the old identifier, then wakes the joiner, whose `__tl_sync` (`pthread_join.c:22`) waits on that
word. The one change is that the tail `for (;;) __syscall(SYS_exit, 0)` becomes `erx_thread_exit`. The joiner returns
only after step 3, and only then calls `__munmap` on the stack (`pthread_join.c:24`). Nothing can create a thread with
the same identifier meanwhile, since `pthread_create` holds that lock across `__clone`. The reaper calls no musl
function, so it cannot wait on the lock it clears.

**Detached.** `__unmapself` (`pthread_create.c:165`) becomes `erx_thread_exit_release(base, size)`, a private `liberx`
entry that puts the range in the record and then does as `erx_thread_exit`.

**Condition variables.** `unlock_requeue` (`pthread_cond_timedwait.c:48-53`) already wakes the next waiter, instead of
requeueing it, for priority-inheriting and process-shared mutexes. The port always takes that branch and deletes
`FUTEX_REQUEUE`, so neither umtx needs a requeue. The cost, one extra wake per waiter, is on
[the performance watch list](todo-performance.md).

#### Task exit

Deleting a task capability does not delete its threads, which the root holds and which keep references to the task
(`task.cpp:686-699`, `thread.cpp:306`). So exit is one service body, reached by a thread's `erx_space_stop(ERX_CAP_SELF,
status)`, which musl's `exit` does, the launcher's `erx_space_stop(task, status)`, or a fault. In the root it is
`erx_machine_end`.

1. **The threads.** `l4_task_delete_obj` on each thread of the task, newest first, reaper and dispatchers included.
2. **The objects.** Its IRQ objects, semaphores and gate, then the task object, which unmaps everything before the call
   returns (`task.cpp:686-699`).
3. **The memory.** Its pages return to the pool, and its range and handle tables are freed.
4. **The status** goes to whoever started the task, as a test's transcript line. A thread that stopped its own task gets
   no reply.

**A request cannot race this.** The service runs each request or fault to completion before it receives the next, finds
the task from the gate's label and each handle in that task's table, and keeps no pointer across a receive. Fiasco IPC
queues no messages: a request is a live thread blocked on the gate, and deleting the thread removes it. So once a stop
returns to the receive, nothing can name that task, and its label is reusable at once.

## Interrupts and readiness

A group is a backend record in its task: executor slots, status page, park lock, parked list, ready ring, listed flags and
dispatcher thread.

* **The dispatcher** blocks in `l4_ipc_wait`. Every message is one IRQ object firing, whose label is the index of its record
  in the group, which the `erx_irq_bind` stub chose. It runs a trigger for that record and waits again, for a device line and
  a software `l4_irq_trigger` alike.
* **The ready ring** has one entry per bound object, and an object is on it at most once, by its listed flag, so it cannot
  overflow and a trigger allocates nothing.
* **`erx_group_take_ready(max)`** drains up to `max` entries, at most `ERX_MSG_WORDS`, under the park lock, clears their flags
  and mirrors `ready`.
* **Ack.** A device line stays masked from delivery until `erx_irq_ack`, Fiasco's own behaviour for a bound IRQ object.

### The park protocol

The protocol of [design-scheduler.md](design-scheduler.md) is kept, with a semaphore per thread, as L4Re's pthread has
(`restart.h:26-37`), in place of the kernel's switch. The four operations are one pure state machine, `park_step`, over the
group's epoch, each slot's epoch, the parked list in order, the ready ring and the listed flags. It reads no clock, makes no
Fiasco call, and returns what the caller does after unlocking.

| Operation | Under the park lock | After the lock |
| --- | --- | --- |
| **Trigger**(object), by the dispatcher | list the object unless listed; mirror `ready`; advance the group's epoch and mirror it; take the longest-parked slot, if any | up that slot's semaphore |
| **Park**(slot, g, s) | if the group's epoch differs from `g` or the slot's from `s`, return `ERX_OK`; otherwise join the parked list | `l4_semaphore_down` with the deadline |
| **Timeout**(slot) | if still on the list, leave it and return `ERX_ETIMEDOUT`; if taken off, return "owed" | if owed, an unbounded `l4_semaphore_down`, then `ERX_OK` |
| **Wake**(slot) | advance the slot's epoch and mirror it; if on the list, take it off | if it was taken off, up its semaphore |

The executor reads the epochs before its empty check. A trigger or wake before the park changes an epoch, so the park returns at
once; one after it finds the slot on the list. With no slot parked, a running executor finds the work at its next safe point.

### The trace ring

M4's `erx:trace` needs a timeline. The root's threads write park, wake, IRQ delivery, task start and task end to one ring of the
inspector schema's records, under the trace lock. The kernel's row reports `unsupported`. Phase 2 adds a source, not a format.

## IPC gates and where transfer fits

No IPC gate is offered above `liberx`. Fiasco IPC is the backend's own transport for requests, faults and IRQ delivery. Gates,
messages and lanes between domains are refused, and capability transfer does not exist, since the one owner never hands a capability
on. This is `moe`'s shape, not a second kernel: the service implements only the table's rows.

### The root service

**One gate per task**, all bound to the service thread, each made with `l4_factory_create_gate(factory, gate, service_thread,
task_index << 2)`. The receive gives the label, with the sender's rights in its low bits (`ipc_gate.cpp:504`), so the decoder masks
them and the rest names the calling task. A task can name only itself. The root's own threads call through the root's gate.

**The wire**, generated from the ABI file, in the native UTCB's message registers:

| Message | Tag label | Words |
| --- | --- | --- |
| request | the call number, or a private number above the ABI's (`reap`) | `mr[0]` the caller's thread index; `mr[1..]` the register arguments in ABI order, then any private word such as the new thread's index |
| reply | zero | `mr[0]` the status; `mr[1..]` the register results |
| fault | Fiasco's negative `L4_PROTO_PAGE_FAULT` or `L4_PROTO_EXCEPTION` | as Fiasco sends them |

**Payloads never cross the native UTCB.** What the ABI puts in the caller's UTCB (the bytes of `erx_debug_log`, up to
`utcb_bytes_max`; starting registers; results larger than the registers) stays in the caller's public UTCB, which the service reads
and writes through the window, by the index in `mr[0]`. So 63 message words are always enough. The ABI's memory windows are reached
through the object's window addresses.

**The loop.** `l4_ipc_wait`; decode; run the body; `l4_ipc_reply_and_wait` with `L4_IPC_SEND_TIMEOUT_0`. A body never calls a stub.

**Refusals.** A label naming no live task is dropped with a counted diagnostic and no reply. An unknown call number, a word count
that differs from the ABI's, a thread index past the table or a payload length past `utcb_bytes_max` is `ERX_EINVAL`; a call without a
row is `ERX_ENOTSUP`. The decoder has a fuzz target. Addresses cross as values, and the service never loads through them.

### Faults, and the fault of the root task

A fault is one more message to the service, which never answers it, because every committed page is already mapped. It names the task,
by the gate, and not the thread, so a crash record's thread field is `unknown`, and it carries the address and instruction pointer.

* **A test task's fault:** the record goes to the log, then [task exit](#task-exit). The machine continues.
* **The root's fault:** [the end path](#the-end-path).
* **The service's own fault** goes to `sigma0`, which repairs nothing: a recorded gap.

## The watchdog, the crash record and the console

### The watchdog

A root thread runs `watchdog.c`'s step machine: sleep one period, step over the pet word. In deterministic mode the step is off and the
machine page says so. A missed pet takes the end path.

### The end path

A root fault and `erx_machine_end` reach it on the service, a missed pet on the watchdog. It is best effort and takes no lock.

1. **One caller.** An atomic exchange of the `ending` word; the loser sleeps forever.
2. **The log.** On the service, which alone writes the log ring, lines the reader has not taken go out through `l4_vcon_write`. On the
   watchdog the service may be mid-write, so the ring is skipped.
3. **The record.** After a fault or missed pet, the crash frame that [design-kernel.md](design-kernel.md) defines and
   `tools/lib/erx/crash_frame.rb` reads, through `l4_vcon_write`. No thread is stopped first.
4. **The end.** `l4_platform_ctl_system_shutdown(L4_BASE_ICU_CAP, reboot)`, with `reboot` 0 for `ERX_END_OFF` and 1 otherwise
   (`platform_control_object.cpp:88`). Under `-no-reboot` this ends QEMU. If the call returns, the thread sleeps until the harness's
   deadline.

### The console

Without `-serial_input`, `Config::serial_input` stays `Serial_no_input` (`config.cpp:246,278-282`), so the kernel never attaches the UART's
receive line, which `Irq_chip_gen::attach` would refuse the driver (`irq_chip_generic.cpp:77-81`). Without JDB a kernel panic halts and the
harness's deadline ends the run.

**The sink** is a variable the service owns. `erx_debug_log` copies `len` bytes from the caller's public UTCB, escapes them, and writes to
`l4_vcon_write` on `L4_BASE_LOG_CAP`, the kernel's polled UART output, or to a ring of `log.c` records. `erx_log_read` runs `erx_log_copy` into
its window for the Erlang log reader. The service is the serialization `log.h` requires.

**The handoff.** The `erx_mem_create_physical` body for the manifest's console UART maps the UART, and on failure returns with the sink
unchanged; it then sets the sink to the ring and replies. The driver's first touch of a register needs that reply, so it follows the service's
last `l4_vcon_write`. A partial boot never maps the entry, so its log lines reach the UART for the whole run.

## littlefs in the system domain

The design's placement is a sub-space port of the storage domain ([design-storage.md](design-storage.md)), which needs a launcher driven from
Erlang, the channel protocol, `erx_program`, exit reporting and the lane reader, with no other Phase 1 consumer. So littlefs runs in the system
domain as a NIF behind the `erx_fs` callback module, the seam the design names. When the port lands, the glue goes and the Erlang side stays.

A process running a dirty NIF cannot run its receive loop, so two share the work. The **owner** takes clients' requests, one at a time, and never
blocks. The **worker**, linked to it, alone calls the littlefs NIF, on a dirty I/O scheduler, one operation at a time.

littlefs reads and programs whole sectors. Its `erase` returns success with no request, since a block device erases nothing. **One block request**,
from a read, program or sync callback:

1. The callback allocates a NIF resource holding a state word, starting *pending*, a result and a buffer. A program copies its bytes into the buffer.
2. It posts `{block, Op, Sector, Count, Ref}` to the owner with `enif_send`, where `Ref` is the resource term and `Sector` is `(Block * BlockSize + Off)
   / SectorSize`. If `enif_send` reports the owner dead, it fails at once.
3. It waits with `erx_umtx_wait(&state, pending, deadline)`, in a loop.
4. The owner translates `Op` into the [block service's request](design-storage.md#interfaces): `{read, Sector, Count}`; `{write, Sector, Bytes}`, with
   `Bytes = payload(Ref)`, a short NIF returning the buffer as a binary; or `flush`. It sends with a monitor and a reply tag, remembers the one
   outstanding `{Tag, Ref}`, and returns to its receive. The resource stays private to the owner.
5. On the answer it calls `complete(Ref, Result)`, a short NIF that copies any read bytes into the buffer, stores `ok` or `error`, moves the state from
   *pending* to *done* by compare-and-swap, and calls `erx_umtx_wake`.
6. The callback, on *done*, copies a read's bytes into littlefs's buffer and returns 0, or `LFS_ERR_IO` for `error`.

**No dirty-scheduler deadlock.** Steps 4 and 5 and the device NIF run on normal schedulers, and interrupts arrive by the dispatcher. One operation holds
one dirty thread, and nothing it waits for needs a second. To keep that true, the owner makes no synchronous call; the owner and driver use no file
operation, and no `logger` handler writes to `/data`; `complete` and `payload` are not dirty NIFs.

**Failure has one answer: the volume is unavailable until reboot.** A block error, a deadline (the callback moves the state from *pending* to *ended*,
and a lost swap means the request is done), or the death of the driver or owner leaves the operation's outcome unknown, and it is reported so. The owner
then answers every request `{error, eio}`. The pair's supervisor does not restart it, and nothing replays or remounts. A late `complete` loses its swap and
does nothing; the term keeps the buffer alive. So a delayed old write cannot race a newer one: there are none until the machine has rebooted, and littlefs's
power-loss design handles the reboot. `design-storage.md`'s rule, which remounts once every outstanding request is answered, belongs to the port.

## Deterministic mode

`erx.det=1` is one CPU, TCG with instruction counting, the interpreter. The harness runs QEMU with `-smp 1` and `-icount sleep=off`. Fiasco's tick comes from
the architecture's generic timer, which instruction counting makes a function of the instructions executed; the time page, deadlines and entropy derive from
that counter and the manifest's seed. ERTS runs one scheduler and the interpreter. The watchdog's step is off. The comparison starts at erXos's banner, or at the
root's first line if Fiasco's own boot proves not deterministic, recorded as a stopgap difference.

## What Phase 1 code must not assume

* **Handles are opaque**, not Fiasco capabilities and not stable across a boot.
* **A committed page is present here, and Phase 2 populates lazily.** Read no timing or fault counts from it.
* **One node today.** Local message delivery is Phase 1's transport and a frame on a lane is Phase 2's.
* **The device NIF keeps physical addresses behind the DMA profile**, and nothing else sees one.
* **Faults reach code as crash records**, never as Fiasco's exception messages.
* **Callers check `ERX_ENOTSUP`**, and show `unsupported` and `partial` as such.
* **No thread is destroyed from outside or stopped.** ERTS's use of threads needs neither.

**A service's request interface is portable.** This is the rule for a service author:

> A service's request interface is the one its design document gives, whatever Phase 1 enforces. A client reaches a service by a pid it was introduced to (the
> facet the domain library hands it at start, or the pid in a reply), never by a registered name of another application, `whereis`, or a module's `start_link`
> return kept across applications. A request and its reply carry portable terms only: atoms, numbers, binaries, lists, tuples, maps, pids and references; never a NIF
> resource, a fun, a port, an ETS table identifier, a `liberx` handle or a Fiasco value. A grant is named by the identifier the server issued for it and nothing else.
> A service reads no table, ETS or `persistent_term`, that another service owns. Local message delivery is Phase 1's transport and a frame on a lane is Phase 2's;
> neither appears in the request's shape. Then moving a service to another domain changes its introduction, not its callers.

The file namespace ([design-files.md](design-files.md)) and the shell's command context ([design-shell.md](design-shell.md)) are the two interfaces to follow first.

## What Phase 1 defers

Every guarantee of `design-kernel.md` (K1 to K33), `design-domains.md` (D1 to D17) and `design-files.md` (F1 to F9). What Phase 1 does instead is in
[the call table](#the-call-table); nothing is rebuilt in user mode.

| Family | Lands |
| --- | --- |
| K1, K2, K17, K21, K24, K25 | Track K's pilot (the capability table), its conformance tests; hostile tests at M5 |
| K3, K32 | Track K's pilot (budgets); M5 (walls, "every charge returns"); M10 (users) |
| K4, K5, K6, K9 | Track K (memory, the TLB planner), conformance tests |
| K7, K12, K13 | Track K; the hostile suites of M2, M5 and M11 |
| K8 | Track K; M7 (the page-table walk); M11 |
| K10, K11, K15 | Track K |
| K14, K20, K33 | Track K; M2 (the executor rule, `ERX_EWOULDBLOCK`) |
| K16 | Track K |
| K18, K26, K27, K28, K29, K30 | Track K; M5 (exit records, `{domain_down, ...}`); Track K's after-the-switch increment (pauses); Track P (signals and upcalls) |
| K19, K31 | Track K; M12 (the lease, the board watchdog) |
| K22, K23 | Track Q |
| groups: C0 to C2, quotas, cohorts, charging, park in the kernel, `erx_group_configure` enforced | M2; M8 (cooperation) |
| umtx in the kernel, across spaces | Track K |
| IPC gates with `ERX_EDEAD`, labels, deadlines, rendezvous passing, fault gates with no cross-domain waits | Track K; M5 (lanes, connections) |
| D1 to D7, D9 | M5 (the funnel's hardening, exports, introduction); M11 |
| D12, D13, D16, D17 | M5; M11 |
| F1 to F5, F9 | M5 (namespaces over connections, grants by introduction); Track S's programs (F9); M11 |
| F6, F7, F8 | Track S's programs (F6); Track Q (F7, F8) |
| SH1, P2, command authority, pipe-end ownership, end of stream by holders | Track S's programs |
| devices: confined DMA, IOMMU windows, MSI, device-buffer lifetime, the device secret | M9; M11 (refused unless configured); M12 (the secret) |
| service CPU admission (facets, lanes, grants), inspection and crash-data authority | M5, M8 (admission); M10 and M11 (authority) |
| the host link holding every facet | M10, M11 |
| entropy in the kernel; the kernel trace ring; deterministic mode at the kernel's level; one route from user mode; every kernel chokepoint; the kernel stack proof | Track K |
| the hostile suites and the security closure | Track K's first part (the call-level hostile domains); M2, M5, M9, M11 |
| the startup proof: `erx_root_plan` run by the packer and the kernel, and its charge evidence ([the root startup rule](#the-phase-1-manifest-check) until then) | Track K's first part, before GK3 |
| the manifest's properties outside Phase 1's scope ([refused records](#the-phase-1-manifest-check)) | M5, M9, M11 |

Not in Phase 1, since they come with toybox and Track S's programs: executables loaded from files, with their supply, seal and install path; signals and `erx_vcpu_control`,
`erx_vcpu_resume`; pipes between programs; the startup message; the channel protocol.

**Recorded gaps**, accepted for Phase 1:

* A fault of the root service hangs every client until the watchdog or the harness's deadline ends the run.
* One thread serves the whole machine, so a long body, such as a task stop's grace periods, delays every other service call.
* A task has at most 128 live threads, and `erx_thread_create` is also `ERX_ENOMEM` while every free record waits for Fiasco's marker write.
* A failed start that did not reach Fiasco's kill path loses that index until the task ends.
* When the watchdog ends the machine, log lines the reader had not taken are lost.
* The crash frame may interleave with a console driver that is writing, and a kernel `WARN` or panic line may interleave at any time.
* Any littlefs block error, deadline or driver restart makes the volume unavailable until reboot.
* A test task's parks and wakes are absent from `erx:trace`.
* `erx_space_create`'s `parent`, `fault` and `label`, and all of `erx_group_configure` but the CPU set, are accepted and ignored.
* A kernel hang or a stalled watchdog thread is caught only by the harness's deadline.

## Verification

Each increment is a QEMU transcript test under TCG and HVF, one and four CPUs, kept in the suite. Each case has a seeded failure, a test-only patch that makes it fail, which shows the case
ran the code it claims to. Host tests and TSan models run the pure cores. M7's parity gate runs the `erx` backend differentially against this one over the test corpus. Fuller recipes live with
the tests.

| Case | Seeded failure, and what it shows |
| --- | --- |
| **Image and banner.** `tools/erx check-boot-image`: the banner image, the two-file form, and the damage cases, each refusing with its reason | a damaged entry that boots fails the case |
| **Native boot.** The root accepts the record through `user_ptr`, reads the archive's last entry, writes one line through `l4_vcon_write`, and shuts down | shutdown removed: the deadline fires. `user_ptr` left 0: the root's accept refuses. The archive's sub-type removed: `sigma0` refuses the map |
| **Memory**, in the root first: commit, write, raise R to RW; decommit and recommit reads zeros; no access and back keeps contents | wrong window page: contents differ. Zeroing skipped: old bytes. Protect takes a fresh page: zeros |
| **Protection**, in a test task: a page of code runs in RX; a write in RX and a run in RW each give the expected fault | the drop step skipped: Fiasco adds rights, so the write succeeds and its fault is missing |
| A stack through `PROT_NONE` then RW; a refused protect, with the pool short, changes nothing | commit on access change removed: a fault. Plan applied page by page: the first page changed |
| **Range table**, host, exhaustive over page states and target protections | a target with write and execute admitted |
| **Thread start**: TLS in the new thread equals the value given | trampoline omits the thread pointer |
| **Failed start**, a hook failing each of the three steps: the status returns, `l4_task_cap_valid` is 0 for the thread, its stack canary is untouched, the next create works | the deletion skipped: the capability stays valid |
| **Claim**, host, a fake kernel writing the marker late, over every order of exit and create | the claim ignores the marker: the fake's write lands on a live thread |
| **Umtx**: a timed wait is never early; host model and TSan, a wake between compare and sleep, a timeout racing a wake | deadline rounded down. Compare outside the lock: a lost wake. Absorb removed: a stale count |
| **Join loop, 10,000 times**: stack and index reused; the joined handle is stale after each join | reaper's steps 1 and 3 swapped: a live handle. Step 3 removed: the deadline fires |
| **Detached loop**: range and index return; the pool's count is steady | range omitted: the count falls |
| `pthread_cond_broadcast` with 64 waiters, one mutex held at a time | the next waiter's barrier left locked: the deadline fires |
| **Park**, host, exhaustive over two executors, two objects and three events; on QEMU, a trigger hooked between the empty check and the park | the epoch comparison removed: a lost wake. An up to a listed slot: a stale count. Hook removed: no immediate returns counted |
| Affinity to each CPU, read back | mask ignored: the wrong CPU |
| **A second task** creates memory and a thread through the service and runs code through a JIT object's read-execute alias. On HVF this also exercises cache maintenance, as coverage, since no omission is sure to show | RW alias mapped RX: the write faults |
| **Task exit**: a spinning thread's count on a shared page freezes; `l4_task_cap_valid` is 0 for every recorded thread; the pool's count returns | thread deletion skipped: the capability stays valid (the count alone can still freeze). Memory step skipped: the pool is short |
| **Request against exit**: one thread loops on `erx_vm_commit` while another faults, 1,000 times, and a new task reuses the label; the dead-label counter stays 0 | thread and gate deletion skipped: requests arrive for a freed label and the counter moves |
| **Task fault**: the record appears, and the machine continues | the fault ends the machine: the next line is missing |
| **Interrupt**: a UART receive and a software object wake a parked executor; `erx_group_take_ready` returns each label once; ack lets the next through | ack removed: the second character never arrives. Listed flag ignored: a label twice |
| **Trace ring**: `erx:trace` shows a park, a wake and an IRQ delivery in order; the kernel's row `unsupported` | the dispatcher's write removed |
| **Watchdog**: a stopped pet ends the machine, its cause in the record | watchdog skipped: the deadline fires |
| **End path**, on a quiet console: a root fault gives the undrained lines and a whole crash frame; `erx_machine_end` with each `how` | the frame's write removed: `crash_frame.rb` reports none. The drain removed: the last line is missing |
| **Console handoff**: lines before and after the create arrive once, in order; a counter of the service's `l4_vcon_write` calls stays still after the create; a failed map leaves the sink alone | the sink never switched: the counter moves |
| **littlefs**: a file operation under `+SDio 1` with a block read in the callback completes | `complete` made a dirty NIF: the deadline fires |
| littlefs: an injected block error fails that operation as unknown, and the next is `{error, eio}`; the driver killed under load: no later writes reach it, and after a reboot a file synced earlier is there | the error swallowed: success claimed. The owner resends: a later write is counted. Sync skipped: the file is lost |
| **Manifest check**: each kept property with a seeded violation, each refusal with a seeded record | [the table](#the-phase-1-manifest-check) is the pairing |
| **Service decoder**: fuzz target, and a task sending an unknown number, wrong count, bad index and long payload | word-count check removed: the fuzz target reports it |
| **Chokepoint**: a Fiasco header outside the backend | the seeded violation is the case |
| **Function-API set** on both backends, refusals included; `make check-reproducible` | a refusal changed in one backend |

## Differences from erXos's kernel

The last column of [the call table](#the-call-table) is this list.

### Transport

The function API is the seam. The `erx` backend's stubs trap into the kernel with the registers of `abi/arch/<arch>.txt`; here the same functions run locally or send
[a request](#the-root-service). No call number or register reaches a caller.

**The public UTCB is not the native one.** `erx_utcb_self` returns the thread's public block, the start of its record, found through the native UTCB's first user word and the
register user mode can read. It has the ABI's `erx_utcb` layout, with `self` holding its own address and `reserved` zero. Fiasco's native UTCB is the backend's alone: its
`free_marker` occupies the offset of the public `reserved`, and each native call overwrites its message registers. So what a caller put in its public block survives any native
call, and no stub takes a snapshot of it.

## Read in source, never run

`tools/erx check-boot-image` and `check-debug-log` have run the load plan, the region reservations, the banner, the descriptor check and `sigma0`'s paging of the root's image, under TCG and
HVF at 1 and 4 CPUs. Everything below was read at the cited lines and has not been executed.

**The native boot package:**

* `user_ptr` reaches the root unchanged, and `sigma0` pages the archive and handoff page read-only by their sub-type: `init_kip.cc:30,80-82`, `init_mem.cc:71-77`.
* `l4_vcon_write`, the ICU capability as platform control object, and shutdown, including power-off, on QEMU `virt`: `platform_control_object.cpp:9,31,88`, `irq_controller.cpp:76`.
* `l4sys` links against freestanding musl: `ipc.h:25-26`. The configuration names for no JDB: `koptions-def.h`, `config.cpp:278-282`.
* Console behaviour under TCG and HVF without `-serial_esc`: `vlog.cpp`, `irq_chip_generic.cpp:77-81`.

**The memory package:**

* `l4_task_map` accepts the root as sender and receiver, and a second map raises rights: `lock_guard.cpp:245-256`, `mapdb.cpp`, `map_util.cpp:640-660,715-770`, `mem_space-arm.cpp:241-270`.
* A window superpage is a parent of page mappings, and unmapping a child leaves it: `map_util.cpp`, `to_fit_size`.
* `l4_task_unmap` of one right leaves the rest, and `L4_FP_OTHER_SPACES` keeps the window's mapping: `task.h:101-135`, `consts.h:200-222`; `fpage_unmap`'s memory path not read.

**The thread package:**

* A 128 KiB area works in `utcb_area` and in `l4_task_add_ku_mem` on the root itself: `task.cpp:253,356,645-649,887`.
* One gate serves as pager and request target, with a root thread calling its own task's gate: `thread-ipc.cpp:254,1020`, `ipc_gate.cpp:504`.
* A return from `l4_task_delete_obj` means the thread never reaches user mode again, whether or not it ever ran, and the marker goes to 0 only when the kernel has finished with the UTCB: `thread.cpp:603-604,657-690`, `thread_object.cpp:157-166,650`, `kobject.cpp:224-233`, `utcb.h:176-185`.
* An unbound thread that never started can be deleted: `thread_object.cpp:161-164`. The semaphore object is built into near-stock Fiasco: `factory.h:470`, `semaphore.cpp:329`, `l4_types.cpp:458`.
* A fault never answered blocks its thread until deleted: `thread.cpp:582-584`; the fault paths not read.
* Grace periods proceed while the service's clients wait: `kobject.cpp:224-233`, `thread.cpp:479-489`.
* Musl's `tid` is used only by `__tl_lock` and mutex ownership, given no signals: `pthread_mutex_trylock.c:8-12`, `pthread_create.c:30-40`.

**Later packages:**

* A bound line stays masked until `l4_irq_unmask`, and a software trigger arrives with the bound label: `irq.h` only; `irq.cpp` not read.
* `enif_send` from a dirty NIF's callback, and its report of a dead receiver: `erl_nif.c:883`.
* Fiasco's boot is deterministic under instruction counting, with medium confidence: its delay calibration and timer setup are unread.
* The size estimates: backend packages 1 to 6, 3,000 to 4,500 lines of C17; the musl port 1,000 to 2,000; NIF glue about 500.

## Open decisions

None for the owner. littlefs's protocol stays here while Phase 1 lasts, and `design-storage.md`, whose target text describes the port, states the placement and links to it.
