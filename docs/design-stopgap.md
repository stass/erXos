# The stopgap binding

The modified Fiasco is erXos's stopgap kernel: until erXos's own kernel
runs the plan's vertical slice, Fiasco, imported as erXos's code under
`fiasco/`, implements the part of erXos's kernel interface that the slice
uses, with the interface's semantics inside the kernel.
[design-kernel.md](design-kernel.md) defines the interface, and its scope
table lists what the stopgap carries
([The current implementation](design-kernel.md#the-current-implementation-the-modified-fiasco)).
This document defines the **binding**: how a kernel call reaches Fiasco
and how an erXos capability lives in Fiasco's object space; how objects
are deleted and who owns each page of kernel memory; how the boot image
is validated, placed and handed to the kernel; the startup plan and the
pool plan that the packer and the kernel share; the seam between the C17
cores shared with erXos's kernel and Fiasco's C++; the crash record's
transport on the console; and what the tests and benchmarks observe.
[design-stopgap-scheduling.md](design-stopgap-scheduling.md) binds the
scheduler's side: stops and exits, park and wake, and server urgency and
charging. Milestone M1 of [plan.md](plan.md#m1-the-stopgap-speaks-erxoss-interface)
builds both.

## Context

Fiasco gives the binding one system call, `sys_ipc_wrapper`
(`fiasco/kernel/src/kern/syscalls.cpp`), reached from the user-mode
synchronous exception vector through `arm_esr_entry` and its
system-call case (`arm/thread-arm.cpp`, `arm/64/thread-arm-64.cpp`); it
dereferences a
capability index held in a register through the task's object space and
calls the object's virtual `invoke`, where each type decodes its own
protocol from the UTCB (`Task`, `Thread_object`, `Factory`, `Ipc_gate`,
`Irq`, the scheduler, the platform-control object, the kernel debugger's
object). Objects (`Kobject`) carry a slot list with a lock, an existence
lock that a deletion invalidates and then waits for, and a put after an
RCU grace period (`kobject.cpp`); `Ram_quota` accounts memory by bytes
charged at each allocation; slab caches shared by every task back the
records (`kmem_slab.cpp`); page-fault and exception messages go to a
pager and an exception handler named per thread (`thread-ipc.cpp`);
helping locks; a fixed-priority scheduler with a 1 ms tick; `bootstrap`,
which loads the kernel, `sigma0` and a root task as ELF modules and fills
a kernel information page and an options block; and `sigma0`, the task at
the root of Fiasco's memory mapping database.

erXos's interface differs where [design-kernel.md](design-kernel.md)
says it does: its own trap convention; 64-bit capabilities whose
generation is checked on every lookup, with rights per type; budgets that
delete what they paid for and own whole pages; memory objects with
ceilings, resolved by the kernel, and no pager; groups with grants;
stops that finish their calls before an exit record (K18); a watchdog
that the root task pets; and a boot image of its own. The binding puts
each of these inside Fiasco rather than above it, so that a test that
passes on one kernel tests the same property on the other.

The stopgap runs development builds only, which run trusted code until
the security closure milestone on erXos's kernel. It is never hardened;
bugs found in it are fixed as anywhere else.

## Requirements

1. **One route.** Every exception from user mode enters through one
   function that classifies it, and every call that names an object
   resolves it through `erx_cap_lookup` with its generation, type and
   rights, in the fork as on erXos's kernel. No path from user mode
   bypasses either, whatever code makes the call: kernel enforcement
   never depends on callers using `liberx`.
2. **The seam.** No Fiasco data model, protocol, header or status code
   reaches anything above the kernel. `liberx`'s `fiasco` backend is the
   only code that knows the stopgap's calling convention.
3. **Decisions in shared cores.** Every decision the interface makes is a
   C17 core shared with erXos's kernel, built and tested on the host;
   Fiasco C++ applies decisions and decides nothing a core decides, and
   the kernel decides on no value it reads from user-writable memory more
   than once.
4. **One image, placed from a plan.** The boot image is validated by
   erXos's validator before any byte of it is copied or run; the kernel
   is placed from a bounded plan that erXos's one executable-header
   reader computed; no inherited ELF code reads the image.
5. **One startup plan and one pool plan.** The root task's charges and
   the kernel's usable memory pool are each computed by one pure
   function, run on the host to admit an image and by the kernel at
   boot, and the kernel checks what it applied and what it holds against
   both; host evidence never substitutes for the kernel's recomputation.
6. **One owner per page.** Every page of kernel memory is held by
   exactly one reserve, which names the budget that paid for it whole,
   or is in the hand of the backing that took it, or waits on the
   released list, or is free in the allocator; a page leaves its reserve
   only through `erx_page_release`, and the list only through
   `erx_released_take`, for the reaper's free step or for a backing.
7. **Deletion in full.** One destroy wins, every attachment is torn down,
   every translation is invalidated before a page is freed, and an
   object is freed once, by the reaper, when its last reference goes;
   a request queued at another CPU counts as a reference on every object
   it names, so no queue holds a pointer to freed memory.
8. **A readable crash record.** The harness reads the crash record from
   the serial log, validates it against its form, and reports a
   truncated or corrupt one as such.
9. **Observable ends.** The harness tells a guest that ended itself from
   one it killed, and every benchmark of gate G1 has a defined endpoint.
10. **A bounded proof claim.** The stack proof covers the C17 cores and
    says so; it never reports a bound on Fiasco's stack.
11. **M1's admission.** The packer admits production native partial
    boots, the empty one included, and refuses, as unsupported, every
    configuration that needs a consumer the tree does not have.
12. **Room for transfer.** M1's IPC carries no capability items, and M5
    adds the rendezvous transfer at a point M1 fixes, without reshaping
    the rendezvous.
13. **Registers from user memory.** A register record a caller supplies,
    at a thread's creation, in `erx_thread_write` or in a vCPU resume,
    reaches the thread's frame only through one generated check that
    refuses every bit user mode may not set and one loader that adds the
    bits the kernel fixes, so no caller can choose a processor mode or
    an interrupt mask.
14. **No inherited allocation.** No object a table can hold and no page
    a budget pays for is allocated by inherited code outside the funnel,
    whether the allocation is in the glue or below it in a Fiasco
    callee.

## Overview

The binding rests on three constructions.

**One route from user mode.** The architecture's vector table has eight
entries for exceptions from user mode. In the fork each of them is one
direct branch to one of three stubs: the synchronous entry
`erx_user_sync_entry`, whose first call is `erx_fault_classify` and
whose only other Fiasco call is the common return path, the rest being
the C17 `erx_entry_step` over the classification's closed result and
what it names; Fiasco's interrupt entry, whose one call
is `irq_handler`; and `erx_user_serror_entry`, whose one call is
Fiasco's asynchronous-error handler. Everything a user-mode exception can
do is therefore decided by `erx_fault_classify`'s closed result: a kernel
call runs the generated `erx_dispatch`, a memory fault runs the fault
decision, and everything else is a fault record. Fiasco's system-call
path (`sys_call_table`, `sys_ipc_wrapper` and the trap handler's
system-call case), the virtual
`invoke` of `Kobject_iface` with every type's protocol decoder, the
factory table, the pager and exception-handler messages, the debugger's
user-mode entry and the debugger's IPC tracing, which rewrote the
system-call table, are deleted from the fork's sources, not listed as
absent: with no vector reaching them and no `invoke` for an object to
implement, there is nothing to refuse. A build check over the vector
table's and the three stubs' disassembly proves the routing, and nothing
else has to be enumerated.

**One object header, one table, one owner per page.** Every object a
capability table can hold is a Fiasco `Kobject` that embeds one
`erx_object_t`, typed at its construction from the validated creation
kind; every table is an `erx_cap_table_t` that `kernel/core/cap.c` alone
reads and writes, with Fiasco's object space reduced to a facade over
it; and every page the kernel allocates is taken whole from Fiasco's page
allocator by the budget-charging funnel, which backs a reserve when it
charges it, is held by one reserve, and leaves it only through the one
release, which ends its charge and puts it on the released list until
the reaper frees it or a backing takes it. So the one lookup,
the generation check, the rights that only shrink, the one slot clear,
the single-winner close, the deletion order and the budget arithmetic
hold in the fork by the same code that holds them on erXos's kernel,
and no budget spends what another was promised.

**Two plans.** The root task's image, stack, kernel-user page, objects,
capabilities, mapping records and translation tables are one plan,
`erx_root_plan`, computed from the boot image and a backend charge
model; the kernel's usable memory is another, `erx_pool_plan`, computed
from the memory map and the backend's allocator rules. The packer runs
both on the host to admit an image; `bootstrap` and the kernel run them
at boot, the kernel applies the root plan through the funnel, and it
refuses to start the root task if the pool it holds or the charges it
applied disagree with either plan.

Three layers carry them:

* **The C17 cores**, `kernel/core/` and `kernel/sched/`, with the
  generated dispatch and decoders in `kernel/generated/`: shared verbatim
  with erXos's kernel, host-built, under the construction rules.
* **The glue**, `fiasco/kernel/src/erx/`: erXos's own C++ inside the
  fork. It owns the fork's kernel objects, implements the effects the
  cores name by calling Fiasco's internal methods, and translates
  arguments and results between the two type systems. It is under the
  chokepoint checks of [Interfaces](#interfaces), not under the stack
  proof.
* **Inherited Fiasco**, changed only where the scope table says
  (`modified`), with its own style.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **B1.** Every exception from user mode enters through `erx_user_sync_entry`, Fiasco's interrupt entry or `erx_user_serror_entry`, the synchronous entry's first call is `erx_fault_classify`, and what follows the classification is the C17 `erx_entry_step` | each of the eight user-mode vector entries is one direct branch to one of the three stubs; each stub's body is the frame-saving prologue and direct calls to the functions it is named for, with no indirect branch; the synchronous stub's `entry.cpp` references no Fiasco internal but the common return path, its other calls being the cores' `erx_fault_classify`, `erx_entry_step` and `erx_dispatch`; the Fiasco functions that decoded user intent are deleted from the fork's sources, so no code implements a protocol an entry could reach | a vector entry pointing at another stub or carrying Fiasco's `ENTRY` template, whose target is a register; a decode of the syndrome in the synchronous entry before the classify call; an indirect call in a stub; a handler revived and called after the classification | `tools/check_vectors.rb` over the fork's `exception_vector` and the three stubs' disassembly, with a seeded vector to a revived `arm_esr_entry`, a seeded `ENTRY`-template entry, a seeded inlined syscall decode ahead of the classify call and a seeded `blr` in a stub, each failing the build; `entry.cpp`'s import allowlist, with a seeded call of a revived `do_syscall` after the classification failing the build |
| **B2.** Every object a call names passed `erx_cap_lookup` in the caller's table | the generated decoder is the only caller of handlers, and only `erx_cap_lookup` turns a capability value into an object; the glue takes no capability value and references no lookup | a handler that takes a raw slot index; a glue function with a capability parameter | the glue's import allowlist and signature check; the hostile suite's stale and wrong-rights capabilities |
| **B3.** The UTCB a thread sees is the ABI file's `erx_utcb`, byte for byte, and the kernel decides on each of its values from one load | Fiasco's `Utcb` (`abi/l4_types.cpp`) and `erx_utcb` have the same layout; the glue reaches it only through the generated accessors; every value a decision needs is in a kernel-owned argument record before any Fiasco internal runs, and no glue function takes a `Utcb *` | a field added to either; a Fiasco internal that re-reads a buffer word | `static_assert`s over every field; the glue's signature check; a conformance case that rewrites a deadline from another thread after the call entered |
| **B4.** The glue decides nothing a core decides | the cores' record types are opaque to the glue, their definitions in `kernel/core/*_impl.h`, which only `kernel/core/*.c` includes; `erx_object_t` is embedded as opaque storage whose fields only the cores name | an `_impl.h` included from the glue; a glue function that branches on a core's result beyond translating it | the include check; the header's opaque storage, which has no field to write; review of each `erx_effect_*` function, which is one translation and one Fiasco call |
| **B5.** The root task starts only as its plans say | the kernel applies `erx_root_plan`'s steps through the funnel and compares the root budget's counters with the plan, after it has compared the pool with `erx_pool_plan`, before it starts the first thread | an allocation outside the plan; a model constant that drifts from Fiasco's sizes; a reservation the pool plan does not know | `static_assert`s of every model constant against Fiasco's types; the two boot refusals; a seeded extra allocation makes the conformance boot refuse |
| **B6.** No byte of a boot image is copied or run before the validator accepted the image, and no inherited code reads an ELF | `bootstrap` opens the image with `erx_pack_open` before it reads any entry, plans the kernel's placement with `erx_elf_plan` and `erx_boot_place`, and copies only what the plan names | an entry read before the open; a call of Fiasco's `exec_load_elf` | the order in `bootstrap`'s one erXos function; `exec_load_elf`, `load_elf_module` and `find_kip` are not built; a malformed image stops in `bootstrap` with the validator's reason; the fuzz targets of both planners |
| **B7.** A crash record read from the console is valid or reported as truncated or corrupt | the frame's header fixes the form and the exact length, the reader reads exactly that many lines and no more, and accepts only a record whose fields check against its form | a reader that accepts a prefix, a length outside the form, or a record whose form differs from the frame's | the reader's fuzz target and its truncated and corrupt fixtures |
| **B8.** The stack proof's claim covers the C17 cores only | the proof's entry list is the cores' exported functions, its allowance is a declared share of Fiasco's thread block, and its report names that scope | a report line that names the kernel stack | the report's wording test |
| **B9.** A page is in exactly one of a live reserve, a backing's hand, the released list or the allocator's free lists, and only the funnel moves it | the funnel charges a reserve and backs it, in the same call, with whole single pages from Fiasco's page allocator, and from the released list when the allocator is empty; a held page is reachable from exactly one reserve (a budget's cache, a thread, a space, a memory object), comes into use only through `erx_reserve_take`, and leaves its reserve only through `erx_page_release`, which appends it to the released list and then refunds its charge; `erx_released_take` alone takes a page off the list, for the reaper's free step, which returns mature pages to the allocator, or for a backing, which waits their grace period itself; so pages held plus pages in backings' hands plus pages released plus pages free is the root budget's guarantee at every instant between parts; Fiasco's slab caches and byte-granular quota are not built, so an inherited callee that still names them fails the link, and the raw page allocator's call sites in the linked kernel are the funnel, the free step and boot-time code | a glue call of the raw allocator; an inherited callee that allocates below the glue; a fault path that reaches the raw allocator; a record that keeps a page after its release; a page returned to the allocator by anything but the free step; a release that refunds before it appends | the glue's import allowlist; the raw allocator's call-site check over the linked kernel's disassembly, with a seeded inherited caller and a seeded fault-path caller failing the build; the released list's append referenced only from `erx_page_release` and its unlink only from `erx_released_take`, with a seeded release that refunds first; the accounting check at the end of the conformance run, which finds the funnel's count of held pages plus the pages in backings' hands plus the released list's length plus the allocator's free count equal to the root budget's guarantee, with a seeded uncharged page failing it, and the kernel design's host model of the accounting for the budget side (K32) |
| **B10.** One destroy wins, and an object is freed once | the existence lock's invalidation is one fetch-or whose old value names the winner; the loser destroys nothing; `refs` is the one count, held by the creation, by threads and by queued requests, and the reaper frees at zero | a second `initiate_deletion`; a per-type reference count; a put that frees; a queued request naming an object it does not hold | the chokepoint rows of [design-kernel.md](design-kernel.md#chokepoint-checks) for the deletion core, applied to the fork; a hosted test that races two destroys of one object under ASan; a hosted test that destroys an IRQ object while its delivery is queued at a thread of another CPU, with the request's reference seeded away and ASan reporting the use |
| **B11.** No register record from user memory reaches a frame unchecked | the thread core admits a record only through the generated `erx_regs_admit`, which refuses any bit of `state`, `fp_control` or `fp_status` outside the architecture file's user mask, and stores it in the thread's record; the glue's one loader, `Erx::regs_load`, copies from that record and adds the fixed bits; no glue function takes a register record | a glue function with an `erx_regs_t` or `erx_uframe_t` parameter; a write of the frame's processor state outside the loader; an admit that masks instead of refusing | the glue's signature and field checks, with a seeded parameter and a seeded write failing the build; the conformance cases that create, write and resume with a privileged bit set and get `ERX_EINVAL`; the generator's test of `erx_regs_admit` with a seeded mask that admits a mode bit |

## Data model

**The object header.** Fiasco's `Kobject`, the one base of every object a
table can hold, embeds one `erx_object_t`
([Objects and capabilities](design-kernel.md#objects-and-capabilities)),
and the Fiasco members that duplicated its fields are deleted from the
fork: `Kobject_mappable`'s slot list, capability count and lock, the
`Ref_cnt_obj` counter of threads, tasks and IRQ objects, and
`Kobject::_next_to_reap`. The header is the one storage; each field has
one owner:

| Field | Owner | On the fork |
| --- | --- | --- |
| `type`, `state`, `ncaps`, `att_slots`, `oid`, `name` | the capability and deletion cores | written only in `kernel/core/` |
| `refs` | the object core | the one reference count; Fiasco's `inc_ref` and `dec_ref` call sites that remain (the kill path's hold on a thread across its request) call `erx_object_ref` and `erx_object_put` |
| `lock`, `existence` | the core decides when; the backend's lock effects act | `erx_hlock_t` is opaque storage of the backend-declared size and alignment (`abi/backend/fiasco.txt`); the glue constructs a `Helping_lock` in `lock` and a `Switch_lock` in `existence` and `static_assert`s that both fit |
| `rcu` | the reaper core | the grace item, a link, a stamp and a callback; the stamped list links through it, and a thread's `Context` embeds the same item, in place of Fiasco's `Rcu_item` base, for its grace-period wait |
| `budget`, `in_budget` | the budget core | the `Erx_budget` that paid for the object and its place on that budget's `att_charged` |

The glue sees `erx_object_t` as an embeddable opaque type: outside
`kernel/core/`, `include/erx/core/object.h` declares it as aligned
storage of a generated size, and the cores, which define
`ERX_CORE_INTERNAL`, see the fields, with a `static_assert` that both
views agree in size and alignment. So the glue can embed the header, take
its address and hand it to a core, and cannot name a field: the opaque
operations are preserved without hiding a type that must be embedded.
One glue function, `Erx::kobject(erx_object_t *)`, returns the enclosing
`Kobject` from the header, and the header is reached from the `Kobject`
by one accessor; both are the fixed member offset. Every object the fork
makes for a table sets `type` in its constructor from the validated
creation kind, and no `Kobject` without a set type is ever installed,
since the one installer takes an `erx_object_t`.

| erXos type | Fork object | Fiasco mechanism inside it |
| --- | --- | --- |
| budget | `Erx_budget`, added | the core's `erx_budget_t` behind the opaque header, charged and refunded only through the funnel, whose `erx_reserve_charge` backs a reserve as it charges it and whose `erx_page_release` ends a page's charge, never the free; with the kind, guarantee, cap, counters, watch, `att_charged` list and caches of [Budgets](design-kernel.md#budgets); Fiasco's `Ram_quota`, its allocator adapters and its factories are not built |
| space | `Task`, modified | the task, its `Mem_space`, the capability table facade, the erXos space state: parent, fault gate, label, the run word holding its run state and live count, the thread list, the mapping records; constructed by the glue's installer, never through `Task::create`'s protocol form |
| thread | `Thread_object`, modified | the thread, its kernel stack, its FP state inline and its one kernel-user page holding the `erx_kupage`; the class, group path, executor slot, `CONTROL` state, the admitted register record and the scheduling binding's record (the one wait record, the kill and dying flags and the finisher) added |
| group | `Erx_group`, added | the scheduler core's group record, the park lock and FIFO, the shared areas as kernel-user memory |
| memory | `Erx_memory`, added | pages from the funnel charged to its budget, the reverse map of mapping records, the ceiling, the reserve; the kernel-made physical kinds wrap pages the kernel owns: the boot image's archive, the time page, the machine page, the device-secret page, the previous crash record, a group's shared areas |
| gate | `Ipc_gate`, modified | the gate with a 64-bit label; its bound thread is an attachment on the thread's `att_gates` list, not a counted reference |
| IRQ object | `Irq`, modified | the IRQ object with a group binding and the final delivery, whose cross-CPU delivery is queued by `Erx::request` and holds its reference in the header's one count |
| resource | `Erx_resource`, added | in M1 the root resource alone: the device-tree entries, the `POWER`, `TRACE` and `ENTROPY` authority, the UART of the early console |

**The slot and the table.** A capability slot is `erx_cap_slot_t` and a
table `erx_cap_table_t`, exactly as [Objects and
capabilities](design-kernel.md#objects-and-capabilities) declares them,
owned by `kernel/core/cap.c`; the table's pages are charged to the
space's budget through the funnel. Fiasco's `Obj_space` becomes a facade
that holds the table and answers Fiasco's own internal queries (the
debugger's listing, `caps_free` at the task's end) through the core's
exported functions; `Obj::Entry`, `Obj::Capability`, `Obj_cap::deref`
and the object mapping database (`map_util-objs.cpp`,
`kobject_mapdb.cpp`) are not built. A capability's 64-bit value, slot
index and generation, is what every register and UTCB item carries;
Fiasco's `L4_obj_ref`, with its flags and 20-bit index, appears nowhere
above the trap.

**The handoff record.** `bootstrap` tells the kernel what it validated
and planned in one record, `erx_boot_handoff`, a layout of
`abi/kernel.txt` embedded in Fiasco's kernel options block
(`koptions-def.h`), which both executables share:

```text
erx_boot_handoff
  u32     version        1
  u32     flags          the image's pack_flags
  u8[8]   build_id       the image's
  u64     image_start    physical address of the archive, page-aligned
  u64     image_size     the archive's total_size
  u64     pool_usable    the pool plan's usable bytes, the free map after
                         rounding
  u64     pool_heap      the pool plan's heap bytes, the ranges the plan
                         selected; Fiasco's kmemsize option carries
                         pool_heap / 1024, exact since pool_heap is a
                         multiple of pool_align
  u32     pool_regions   the heap ranges the plan selected
  u32     bootargs_len
  u8[]    bootargs       /chosen/bootargs, at most boot_strings_max bytes,
                         cut at the last whole word
```

**The charge model.** `abi/backend/fiasco.txt` declares, as `charge`
lines, the byte cost on this backend of each thing the startup plan and
the domain planner charge: a thread's block (`THREAD_BLOCK_SIZE`, 8 KiB
in the fork's configuration, which holds the record and the kernel
stack: two pages in a slot of the thread region, **Budgets and the
ownership of pages** below), a task's record, a gate's, an IRQ
object's, a group's per-CPU records, a memory object's record, a mapping
record, a capability-table page, a translation table, a kernel-user
page, and `boot_reserve`, the bound on what Fiasco's own boot takes from
the pool before the root task is created, as a base, a per-CPU term and
a per-heap-page term for the page records and the thread region's
tables; and as `size` lines what the cores embed from the backend:
`hlock`, the lock storage. The generator
emits them as `erx_charge_model_t` constants for C, on the host and the
target, and for Ruby, and the glue holds a `static_assert` for every
constant that names a Fiasco type's size, so a change to Fiasco's
objects that the model does not follow fails the kernel build.

**The pool model.** The same file declares the allocator's rules the
pool plan reproduces: `pool_align`, the unit Fiasco's free map rounds to
(its superpage, 2 MiB: conventional memory inward, every reservation
outward, `kmem_alloc.cpp`); `pool_window`, the kernel's physical-memory
window (1 GiB on the fork's AArch64 layout, `Mem_layout::Pmem_start` to
`Pmem_end`), within which the heap and the archive's alias must fit,
each mapped by `Kmem_alloc::map_pmem` from the window's start upward,
while the kernel's own image lives above the window at `Map_base` and
takes no room in it; `pool_regions_max`, the limit on physical-memory
regions (`Mem_layout::Max_pmem_regions`, 8), which the kernel image's
region, registered by `add_initial_pmem`, the alias and every heap range
share; and `loader_reserve`, the bound on what the loader places that
the packer cannot know the address of: `bootstrap`'s own image and the
device tree, each counted at its size plus two units. Two more `size`
lines fix the smallest view the kernel's metadata headers may report
(**The placement plan** below): `kip_size`, one page, and
`koptions_size`, the size of Fiasco's `L4_kernel_options::Options`,
each asserted against the Fiasco type in the glue.

**The startup plan.** `erx_root_plan(spec, model, plan)` in
`kernel/core/root_plan.c` is pure over `spec`: the root entry's image
manifest (its segments with their file and memory sizes, protection and
flags), the stack size, the capability limit, the CPU count, the sizes
of the root objects' fixed pages, and the boot information page's
strings. It yields `erx_root_plan_t`: the addresses of the image's
segments, the stack, the kernel-user page and the boot information
page; the first thread's start registers (the entry, the stack top, and
the boot information page's address in the first argument register the
architecture's ABI file names); a list of steps, each `(kind, count,
bytes)`, in the order the kernel applies them: the root budget's record,
the space, the root and `system` groups, the root resource, the boot
image's object and the root entry's slice, the time page, the machine
page, the device-secret page, the capability table's pages for the root
slots, the mapping records and translation tables of every mapping, the
kernel-user page's mapping included, the private pages of the writable
segments and the stack, the thread with its kernel-user page, and the
boot information page; and `total`, the sum of the bytes in pages. The
plan fails with the status of the first check that fails, and nothing
is applied.

**The pool plan.** `erx_pool_plan(map, model, plan)` in
`kernel/core/pool_plan.c` is pure over `map`: the conventional ranges
and the reserved ranges (the kernel's placed segments, the archive,
`bootstrap`'s image, the device tree, every `/reserved-memory` entry).
It rounds each conventional range inward and each reservation outward
to `pool_align`, exactly as `Kmem_alloc::create_free_map` does, and
yields `erx_pool_plan_t`, four figures and one list:

* `usable`, the bytes the free map holds after rounding: conventional
  memory rounded inward, less every reservation rounded outward. It is
  not Fiasco's `available_size`, which sums the conventional ranges
  before any reservation is subtracted and serves only its sanity
  check.
* `alias`, the archive's reservation rounded outward, which the kernel
  maps into its window beside the heap.
* `heap`, the ranges the heap takes, chosen as `Kmem_alloc`'s
  constructor chooses them (`kmem_alloc-arm.cpp`): from the highest
  range of the free map downward, each range whole, the last cut to its
  top so the total is exact. The total is the smaller of `usable` and
  `pool_window - alias`, a multiple of `pool_align` since every range
  is: the whole free map, cut only where the window binds. `heap` is
  the sum of the list; `regions` its length. The region limit is an
  admission rule, not a selection input: a free map of more than
  `pool_regions_max - 2` ranges fails the plan, the kernel image's
  region and the alias being the other two. Fiasco's constructor takes
  ranges from the top until `kmemsize` is met and panics when
  `Mem_layout::add_pmem` refuses a region past the limit, so a plan
  that let the limit choose a prefix would make the heap depend on
  which ranges lie highest, and more RAM or a loader placement near the
  top of memory changes that: six small ranges above one large range
  would push the large one out of a six-range prefix and shrink the
  heap when memory grew. With the limit as a refusal, `heap` depends on
  the free map only through `usable`, which more RAM and smaller
  reservations never reduce; that is the monotone relation the host's
  admission rests on (**The startup plan and its charge evidence**). The
  limit holds at boot over the actual map, and on the host over the
  platform's table, where the loader's two placements have no address
  and count as two more ranges, since each splits at most one range.
* `kmemsize`, in KiB, is `heap / 1024` and nothing else: Fiasco rounds
  the option up to its superpage (`determine_kmem_alloc_size`) and
  panics when the free map cannot fill it (`kmem_alloc-arm.cpp`), so
  the plan never asks for more than the list it selected.

A map that leaves `heap` below the model's floor fails the plan, and so
does an archive whose rounded alias meets the kernel image's rounded
region, which `Mem_layout::add_pmem` would refuse (`mem_layout-arm.cpp`):
the placement plan checks that case before any byte is copied.

**The placement plan.** `erx_elf_plan`, erXos's one reader of
executable headers ([design-programs.md](design-programs.md#what-a-program-can-start)),
gains a **kernel profile**, an argument of the pure function: an
executable linked at fixed physical addresses, placed at each segment's
physical address, with up to 16 loadable segments, protection ignored
since translation is off when `bootstrap` copies. Every offset and
size is checked against the entry's bounds, as in the program profile.
The profile reports two **views** besides the placements: the kernel
information page and the options block, which Fiasco's link script
marks with custom program-header types (`l4_kip` and `l4_koptions`,
`kernel.arm.ld`) over sections that a loadable segment also covers. A
view is not a placement. The reader requires exactly one header of each
type, with `memsz` equal to `filesz` and at least the model's `kip_size`
or `koptions_size`, contained in one loadable segment's file-backed part
with the same file-to-physical offset
(`view.paddr - load.paddr == view.offset - load.offset`), and reports
it by its placed address and size; a second header of a type, a view
too small, outside every segment, straddling two, or at another offset
fails the plan. `erx_boot_place(elf_plan, map, place)` in
`kernel/core/boot_place.c` then checks each placed range against
conventional memory, the archive, `bootstrap`'s image, the device tree
and every other placed range, checks that the archive's and the
kernel's extents stay disjoint after both are rounded outward to
`pool_align`, so the kernel's `add_pmem` cannot later refuse the alias,
and yields the copy list `bootstrap` executes and the reservations the
pool plan takes. The views need no check there: each lies inside a
placed range. Both profiles share the reader's fuzz target, and
`erx_boot_place` has its own.

## Algorithms and behavior

### Transport

The vector table of `arm/64/ivt.S` has eight entries for exceptions from
user mode: a synchronous exception, an interrupt, a fast interrupt and
an asynchronous error, for each of the two user-mode execution states.
In the fork, the synchronous entries branch to `erx_user_sync_entry`,
the interrupt entries to Fiasco's interrupt entry `.Lirq_entry`,
unchanged, and the asynchronous-error entries to `erx_user_serror_entry`,
a stub the fork adds: the frame-saving prologue, a direct `bl` to
Fiasco's `arm_serror_handler`, unchanged (the scope table's weaker row),
and the common return path. Fiasco's own `ENTRY` template, which the
asynchronous-error entries used, loads the handler's address into a
register, branches to a shared `.Lgeneric_entry` and calls through the
register (`ivt.S`); a direct stub has no register to point elsewhere.
`erx_user_sync_entry` saves the frame as Fiasco's generic entry does,
then calls `erx_fault_classify` with the syndrome
([Threads and faults](design-kernel.md#threads-and-faults)) and hands
its closed result to `erx_entry_step`, a C17 function whose exhaustive
switch names one effect per result:

* **a kernel call**, erXos's immediate `0x4552`: the glue's `erx_syscall`
  copies the six argument registers and the call number out of the
  frame into a private snapshot, as `erx_sys_decode_shape` takes them,
  and calls `erx_dispatch` with a context that names the calling thread,
  its class and its space's table; on return it writes the status and
  two results into the frame's result registers and preserves the rest.
  The registers are the ones `abi/arch/aarch64.txt` names; the copy is
  generated from those lines, so no register is picked by hand.
* **a memory fault**: the fault decision over the space's mapping records
  ([Faults, and the fault of the root task](#faults-and-the-fault-of-the-root-task)).
* **a fault record** for everything else: another system's trap
  immediate, Fiasco's own zero included, is `ERX_FAULT_FOREIGN_TRAP`; a
  breakpoint is `ERX_FAULT_BREAKPOINT`, never a debugger entry; the
  other-execution-state synchronous entry, which no thread can reach
  since the kernel starts every thread in the one state it supports,
  classifies as `ERX_FAULT_UNDEFINED` like any instruction the kernel
  does not support.

Fiasco's `arm_esr_entry` with its system-call case, `do_syscall`, `sys_call_table`,
`sys_ipc_wrapper`, `Thread::handle_page_fault_pager`,
`Thread::send_exception`, `Thread::exception`, `Kobject_iface::invoke`
with every type's override, `Kobject_iface::factory`, `Obj_cap::deref`
and the alien-thread state are deleted from the fork's sources, and
with them the debugger's IPC tracing, which switched the deleted
system-call table between the plain and the logging wrapper
(`Jdb_set_trace::ipc_tracing` and `set_ipc_entry`,
`jdb/arm/jdb_trace_set-arm.cpp`, `jdb/arm/64/jdb_trace_set-arm-64.cpp`,
and `sys_ipc_log_wrapper`, `kern/syscalls-log.cpp`): the debugger's
trace commands lose their IPC modes, and the trace ring of
[design-kernel.md](design-kernel.md#trace-ring) is the stopgap's
tracing. The proof that nothing reaches a protocol is the vector check,
not a list: `tools/check_vectors.rb` disassembles `exception_vector`
and the three stubs and requires each of the eight user-mode entries to
be exactly one direct branch to one of the three stubs, and each stub's
body, from its label to its first direct call, to hold only the
frame-saving prologue, with no other call, no branch out of the stub
and no indirect branch anywhere in the stub; the first call is
`erx_fault_classify`, `irq_handler` or `arm_serror_handler` by stub.
What follows the classification is covered by two more checks: the
synchronous stub's `entry.cpp` has an import allowlist of its own,
the common return path and nothing else of Fiasco's, its other calls
being the cores' `erx_fault_classify`, `erx_entry_step` and
`erx_dispatch`, so a handler revived and called after the
classification fails the build;
and `erx_entry_step`'s switch is exhaustive over the closed result with
no default arm and names only `erx_effect_*` functions, under the
cores' rules. The debugger of development builds is entered from the
console's escape sequence and from a kernel panic, after the crash
record is complete, never from user mode.

**The UTCB.** Fiasco's `Utcb` is the ABI file's `erx_utcb`: 63 message
words, the thread's own address, the buffer descriptor, 58 buffer
words, the error word, one reserved word and three user words, 1 KiB at
the start of the thread's kernel-user page. The kernel reaches it
through its kernel alias and only through the generated
`erx_shared_load_*` and `erx_shared_store_*` accessors, which load each
field once per decision (K7); invariant B3 pins the layout. Every value
a decision needs, the tag, the deadlines, the buffer descriptor's slot
count, is loaded once by the generated decoder into the call's argument
record, and the glue passes those values to Fiasco's internals as
arguments: `do_ipc` takes each phase's deadline as an absolute kernel
clock value, from which the glue arms a Fiasco `Timeout`, so
`L4_timeout`, `L4_timeout_pair` and `microsecs_abs`, which re-reads a
buffer word after the decode (`abi/l4_types.cpp`), are not built. The
message words move by `erx_msg_copy`, a bulk copy of the decoded word
count between the two kernel aliases, in place of `copy_utcb_to_utcb`;
no item transfer and no FPU transfer run in M1. No glue function takes a
`Utcb *` or a `Syscall_frame *` but `erx_syscall`'s frame, which the
signature check of [Interfaces](#interfaces) enforces. The vCPU state
area lives in the same page at `erx_kupage`'s offset (M5), so a thread
has one kernel-user page, as the cost model counts.

**Status codes.** A handler returns an `erx_status_t`. Where the glue
calls a Fiasco internal that reports a result of its own (an allocation,
`do_ipc`, a timeout), it translates that result with one exhaustive
`switch` over the internal's enumeration, with no default arm, into the
statuses the ABI file declares for the call, so a Fiasco code that the
mapping does not name fails the build; `L4_error` and `L4_msg_tag`
never reach a register or the UTCB's error word. The conformance suite
drives every declared status of every call.

**Registers from user memory.** Three calls hand the kernel a register
record a caller wrote: `erx_thread_create`, whose start registers are
in the caller's UTCB; `erx_thread_write`, one set per call; and
`erx_vcpu_resume`, whose frame is in the state area (M5). The return
path restores the saved processor state word into the hardware without
looking at it (the return macro of `arm/64/ivt.S`), so a record copied
as written would let a caller choose a privileged mode or mask
interrupts for its own thread; Fiasco guards its own paths with
`sanitize_user_state` and `Entry_frame::copy_and_sanitize`
(`arm/context-arm.cpp`, `arm/64/entry_frame-arm.cpp`), which force
user mode and interrupts enabled on every copy. The fork's construction
has no copy to guard: the thread core stores a record only through
`erx_regs_admit`, a pure function the generator emits from the
architecture's ABI file, which declares for `state`, `fp_control` and
`fp_status` the **user mask**, the bits user mode can observe or change
([design-arch-aarch64.md](design-arch-aarch64.md#thread-state)), and for
`state` the **fixed value** the kernel sets, user mode's own mode with
interrupts unmasked. The admit refuses a record with any bit outside the
user mask with `ERX_EINVAL`, so a caller cannot ask for a mode or a mask
and a round trip through `erx_thread_read`, which reports `state` as
`state & user mask`, always succeeds; it never masks silently, since a
record that names a privileged bit is a bug or an attack, not a
preference. The admitted record is the thread's stored `erx_regs_t`,
which only the core writes. The glue's one loader, `Erx::regs_load`,
copies that record into Fiasco's frame and ors the fixed value into
the state word; a `static_assert` in the glue holds the fixed value
equal to what Fiasco's `sanitize_user_state` sets, so the two kernels
agree on what user mode is. No glue function takes an `erx_regs_t` or
an `erx_uframe_t`, and the frame's state word is written in the loader
and nowhere else, which the field check enforces (B11). The sets
`erx_thread_write` accepts are the ABI file's `erx_regs` and the FP
set; neither holds the thread-pointer register that names the
kernel-user page, which the kernel writes at creation and no call
changes.

**The first entry of a thread.** Fiasco's `Thread::user_invoke`
(`arm/thread-arm.cpp`) clears the general registers and loads kernel
information into one of them. The fork's `user_invoke` instead calls
`Erx::regs_load` over the thread's stored record, which
`erx_thread_create` admitted from the caller's UTCB through the one
accessor and the root plan filled for the first thread; nothing else is
written, so a thread's first user instruction sees exactly the register
set the ABI file's layout names and zeros elsewhere.
`user_invoke_generic`, which takes pending requests and releases the
CPU lock, stays, and the exit joins Fiasco's common return path
(`__return_from_user_invoke` into `.Lret_from_exception`), so a first
entry passes the same return check as a call's return
([design-stopgap-scheduling.md](design-stopgap-scheduling.md#stop-and-exit)).

**FP and SIMD state.** Fiasco's lazy FP switching (`CONFIG_LAZY_FPU`,
`Kconfig`) lets a thread's first FP instruction trap so that
`Thread::handle_fpu_trap`, reached from `arm_esr_entry`'s trap case
(`arm/thread-arm.cpp`), allocates its state and enables the unit. That
handler is deleted with the dispatcher, so the fork switches eagerly and
makes lazy switching unconfigurable rather than merely unset: Fiasco's
`CONFIG_PERFORMANCE` carries `select LAZY_FPU if FPU && HAS_LAZY_FPU`,
which a `# CONFIG_LAZY_FPU is not set` line in a defconfig cannot
override, since a `select` wins over the file. The fork's `Kconfig`
therefore drops that `select` line from `PERFORMANCE`, drops
`HAS_LAZY_FPU` from the architecture's `ARCHSELECT` list
(`kern/arm/Kconfig`), and deletes the `LAZY_FPU` option together with
the lazy implementation it guarded, so no configuration of the fork can
express lazy switching. What remains is the eager implementation: the FP
unit is enabled for every thread, `Context::switch_fpu` saves the
outgoing thread's state and restores the incoming one's at every switch
(`context.cpp`), no FP trap ever occurs, and the trap class is a fault
record like any instruction the kernel does not support. erXos's kernel switches the same way
([design-arch-aarch64.md](design-arch-aarch64.md#fp-and-simd-state)). The state
itself, `Fpu_state_simd` (`arm/64/fpu-arm.cpp`), lives inline in the
fork's `Thread_object`, in the thread block the thread already owns,
where erXos's thread record holds it too (`erx_saved_thread`,
`abi/arch/aarch64.txt`); `fpu_state()` names that member. So there is
nothing to allocate, charge, transfer or free: `Fpu_alloc` with its
global slab (`fpu_alloc.cpp`), `alloc_state`, `free_state`,
`ensure_compatible_state` and `Thread::transfer_fpu` are not built, the
thread block's charge covers the state, and a `static_assert` in the
glue holds that the record with the state leaves the block the stack
allowance of `kernel/stack_fiasco.txt`. `CONFIG_ARM_SVE` is off as
well, since the SVE trap handler lives in the same dispatcher and the
state size would otherwise depend on the vector length; SVE and SME
stay trapped and classify as `ERX_FAULT_UNDEFINED`, as on erXos's
kernel.

**The IRQ shortcut is off.** `Config::Irq_shortcut`
(`arm/config-arm.cpp`) is zero in the fork. Fiasco's shortcut
(`Ipc_sender_base::handle_shortcut`, `ipc_sender.cpp`) wakes a thread
waiting in `do_ipc` by building its return frame and leaving through
`fast_ret_from_irq`, discarding the C++ frames of the call the thread is
in, which is why `do_ipc` requires a disposable stack. The binding's
completion, the status translation and the decoder's cleanup, runs
after `do_ipc` returns, so a wake must return through those frames:
with the shortcut off, every wake of a thread out of a wait, by a
sender, an IRQ object, a timeout or a cancel, switches to the thread
and lets it return through `do_ipc`'s C++ frame and the common return
path. erXos's kernel keeps nothing alive across a sleep and completes
every wait through one function (K33 of
[design-kernel.md](design-kernel.md#execution-model-and-locking)), which
is what makes a resume straight from an interrupt handler safe there;
the stopgap's frames do hold state across the sleep, so the shortcut
stays off. The `timer` and `park` benchmarks measure what it would
have saved.

**`sigma0` and the mapping database.** The kernel creates the `sigma0`
task as Fiasco's boot does, from the fork's workload step, before the
root budget exists and within `boot_reserve`, as a plain `Task`: it is
the task Fiasco's code takes for the root of physical memory
(`Mem_space::is_sigma0`), and it exists so that inherited code that
assumes a root task finds one. No thread is ever started in it and
nothing can send to it. Since no thread runs there, the boot image
carries no `sigma0` executable: nothing in the kernel but
`init_std_workload`, which the fork does not build, reads the
information page's `sigma0_ip`. Fiasco's memory mapping database, which
its boot roots at `sigma0` (`init_mapdb_mem`, `map_util-mem.cpp`), is
not built: `mapdb.cpp`, `mapping_tree.cpp`, `mapping.cpp`,
`map_util.cpp`, `map_util-mem.cpp`, `sigma0_task.cpp`, the debugger's
`jdb_mapdb.cpp` and the `mapdb` preprocessor part (`config.cpp`) leave
the fork's module lists (`Modules.generic`, `Modules.arm`). Every
reader of the database was a native protocol: the flexpage map and
unmap of `Task`, the item transfer of `thread-ipc.cpp`, the vCPU map of
`thread_object.cpp`, the page-fault path with `Sigma0_task::v_fabricate`
and the unmap `Task::destroy` ran over all spaces, which the fork's
space teardown replaces (**Deletion**). So there is no `Treemap` slab
to replace, no root `Physframe` array to count in `boot_reserve`, and
no second owner of a mapping: the reverse map of erXos's mapping
records is the one. The debugger's memory listing
(`jdb/jdb_kern_info_kmem_alloc.cpp`) keeps the page allocator's dump
and loses its loop over `Kmem_slab::reap_list`, since the fork has no
slab allocators.

### Capabilities in Fiasco's object space

The capability core is the kernel design's, applied to Fiasco's objects
through the header: a creation installs the new object into the
creator's table with `erx_cap_install`; `erx_cap_dup` adds a slot to the
object's list, where Fiasco's object map would; `erx_cap_close` and the
emptying walk clear slots only through `erx_cap_slot_clear`; the lookup
reads a slot under its sequence count and takes no lock
([Objects and capabilities](design-kernel.md#objects-and-capabilities)).
The locks are Fiasco's, in the header's storage: the capability lock is
a `Helping_lock` and the existence lock a `Switch_lock`, which the
generated decoder takes for the arguments the ABI file marks `exists`
through `erx_object_lock_existence`.

**`erx_cap_pass` in its creator's case** (M1) runs `erx_pass_plan` and
`erx_pass_apply` from one table into the other under both tasks'
existence locks, in address order, as Fiasco's `Task::sys_map` takes
both tasks' locks; it uses no Fiasco map item, since the object mapping
database is not built.

### Deletion

Deletion is the kernel design's three phases
([Closing and deleting](design-kernel.md#closing-and-deleting)), run by
the C17 deletion core, `kernel/core/delete.c`, over Fiasco's mechanisms.
Four things make it hold in full on the fork:

* **One close winner.** The close is one atomic fetch-or on the existence
  lock's owner word, Fiasco's `Switch_lock::invalidate` changed to return
  the word's old value: the caller that finds the bit clear is the one
  destroy that goes on; every other caller, a second `erx_object_destroy`
  that passed lookup before the close, a release racing a delete, a
  budget's destroy, finds it set and returns, destroying nothing. Only
  the winner pushes the object onto a reap list, through the header's
  `rcu` link; `Kobject::initiate_deletion` is not built.
* **One reference count.** `refs` in the header is the only count:
  one for the creation, one for each thread that keeps the object across
  a wait or a preemption point, and one for each **queued request**
  that names the object. Fiasco's `Ref_cnt_obj` is deleted from the
  fork; the kill path's hold on a thread across its request to the home
  CPU is an `erx_object_ref`. Objects never count references to each
  other: every pointer between object records is an attachment of the
  target, so a gate's bound thread is on the thread's `att_gates` list,
  the gate's `_thread` pointer being protected by that list, and the
  counted reference `Ipc_gate` took on its thread is gone.

  A request to another CPU is of two kinds. A request its requester
  waits for (`Context::drq`, `Drq::Wait`) names the requester, alive
  because it is waiting, and the target, alive because the request sits
  in the target's own queue; it needs no reference, and the fork's
  `Context::drq` has no other mode. A request its requester does not
  wait for, the IRQ object's delivery to a thread on another CPU
  (`Irq_sender::send` and `handle_remote_hit`, `irq.cpp`) and the kill
  and migration helpers run on the kernel context, holds a pointer in a
  queue after the requester has moved on. Fiasco keeps the IRQ object
  alive across such a request with a separate send reference and a
  send-state word (`Irq_sender::destroy`, `finish_send`,
  `reject_send`); the fork folds that into the one count: every such
  request is queued by one glue function, `Erx::request(target, func,
  object)`, which takes `erx_object_ref` on the object it names before
  it queues. That reference is the delivery's, not the queue entry's:
  it goes with the record wherever the handler puts it, into the
  receiver's sender list or an unbound gate's blocked list, and is
  dropped by the one step that takes the record, the receive that
  completes the send, or withdraws it, the receiver's death drain
  forwarding it to the object's next binding or holding it at the gate
  with the reference, the gate's destroy or the object's own teardown
  dropping it; a handler that delivers at once drops it itself. So a
  destroy that wins while the request is queued runs its teardown, and
  the record outlives every queue the delivery sits in until the
  delivery is taken or withdrawn, as Fiasco's `Irq_sender` outlives its
  queued send by its own send reference
  ([Posting and publishing](design-stopgap-scheduling.md#stop-and-exit)).
  Both `Erx::request` and `Context::drq` refuse a thread past its dead
  mark, which `do_kill` writes under the thread's request queue's lock
  before it drains the queue, and which the enqueue reads under the
  same lock, so a request queued before the mark is run by that drain
  and one sent after it is refused, and none is left in a queue nothing
  drains. `Context::enqueue_drq` is private to `Context` with
  `Erx::request` and `Context::drq` as its only friends, so no third
  way to queue exists.
  Since the stop binding's abort requests are eager and a queued
  delivery is not, an abort can run before the delivery it was meant to
  follow; no handler relies on their order: the delivery's handler
  re-reads the binding under the IRQ lock when it runs, as
  `handle_remote_hit` does, and delivers to the thread it finds bound,
  forwards to a new one, or withdraws into `PENDING` when there is
  none, each a transition of the IRQ object's own table
  ([IRQ objects](design-kernel.md#irq-objects)). A put that reaches
  zero never frees: it hands the record to the reaper through the
  header's link, so a free happens on the reaper's path alone, whatever
  context the last put runs in.
* **Attachment teardown.** The type's teardown walks every attachment
  field of its record and removes both ends: a thread's teardown unbinds
  each gate on `att_gates`, so senders queued there wake with
  `ERX_EDEAD`; a gate's removes itself from its thread; a memory object's
  removes every mapping on its reverse map, marking it deleted; a space's
  runs the space teardown below; a budget's deletes every object on
  `att_charged`, child budgets included, iteratively. After the teardown
  the object holds nothing and nothing holds it but the threads counted
  in `refs`.
* **One reclamation path.** After the grace period the reaper drops the
  creation's reference; at zero it frees the record alone: its slot
  returns to its budget's cache, and the cache page is released when
  the free leaves it empty; a thread's record is its block, whose two
  pages the free releases (**Budgets and the ownership of pages**).
  The object's other pages were released by its teardown, their charge
  ending there, before the grace period began. The free of a record
  returns a slot and refunds nothing; only when it leaves the cache page
  holding no record is that page released, which refunds the page to
  its budget as any release does. `Kobject::put` on the fork is that drop, one implementation
  for every type; the per-type `put` overrides that freed a thread or
  dropped a gate's thread are deleted.

**Space teardown.** `Task::destroy` on the fork does not call
`fpage_unmap` over the mapping database, which holds no erXos mapping
and would skip every one of them (`map_util.cpp`). It runs three steps
in the order the stop binding fixes
([design-stopgap-scheduling.md](design-stopgap-scheduling.md#stop-and-exit)).
First the stop binding's part: the stop of the space and the kill
request to each of its threads. Then the emptying walk of the
capability table, in bounded parts through `erx_cap_slot_clear`: the
walk that `erx_space_clear_caps` runs for a holder of `CAPS` from M5,
run by every destroy from M1, since a destroyed space's slots must go.
Then the C17 space teardown: in bounded parts, each mapping record is
detached from its object's reverse map and its translation entries
cleared through `erx_tlb_plan`, applied by `Mem_unit`; the plan's last
step, after every invalidation has completed, releases the detached
tables and the pages of the space's private memory, pooled or in use,
through `erx_page_release`, as `erx_vm_unmap` does, and invalidates
the space's ASID. The root directory it keeps: every entry of it is
cleared by then, so it translates nothing, and it stays the space's one
held page, `_dir` and `_dir_phys` pointing at it, until the space's
record is freed. The reason is the fork's finishing threads: a thread
of the stopped task runs the rest of its call on its own CPU and dies
at its return boundary
([design-stopgap-scheduling.md](design-stopgap-scheduling.md#stop-and-exit)),
and until its death edge it can be switched to, and every switch to it
runs its space's switch path, `Context::switchin_context` into
`Mem_space::make_current`, which loads `_dir_phys` into the user table
base register (`arm/context-arm.cpp`, `arm/64/mem_space-arm-64.cpp`).
A directory released at the destroy could be free and reused by then,
and the CPU would walk another owner's memory for any user address it
speculates on; clearing `_dir` alone changes nothing, since the switch
reads `_dir_phys`. A kept directory with no valid entry translates
nothing for any ASID the switch may give it, `asid()` reallocating one
for a closed space as for any other when Fiasco's generation rolls
(`mem_space-arm.cpp`). `Mem_space::~Mem_space`, which on stock Fiasco
walks the user and kernel levels and frees them and the root directory
at record reclamation (`mem_space-arm.cpp`), does one thing on the
fork: it releases the root directory through `erx_page_release`,
refunding at the space's budget, live or dead. It runs from the
reaper's put at the record's free, after the last thread's `unbind()`
has dropped its reference on the space and the grace period has ended,
so no CPU can switch into the space again; a debug build asserts in
`make_current` that the page `_dir_phys` names is held. So every page
the space held but one is on the released list, its charge ended,
before the destroy returns, and only the reaper's free step turns it
free; the one page follows at the record's free, as a thread's block
does. The destroy
does not wait for the exit record, which the stop binding posts at the
last thread's death.

### Budgets and the ownership of pages

An `Erx_budget` is the core's `erx_budget_t` behind the glue's opaque
header, with the kernel design's kind, guarantee, cap, counters, watch
and `att_charged` list ([Budgets](design-kernel.md#budgets)); Fiasco's
`Ram_quota`, which accounts bytes at each allocation, is not built, and
nor are its two allocation adapters, `Kmem_q_alloc`, which allocates and
frees raw blocks around a quota, and `Kmem_alloc::q_allocator`, which
hands it to `Mem_space` for its tables (`kmem_alloc.cpp`): what remains
of them is replaced below, not wrapped. Every change of a budget's
counters is the C17 `erx_budget_adjust`, so guarantees, caps, the
borrowing chain, walls, resizing, the watch and the close of a destroyed
budget are the same code as on erXos's kernel, and the only thing the
fork charges is a **whole page**, held by a reserve. A reserve is backed
when it is charged, a charge ends when the page is released, not when it
is freed, and a fault never allocates: the funnel meets the six-entry
interface the kernel design fixes for every implementation
([The reaper](design-kernel.md#the-reaper)), over Fiasco's buddy
allocator and its RCU batch numbers, under the core's ticket lock,
since the kernel design's bounds need a lock served in order (K13); on
the fork every Fiasco `Spin_lock` is built on that lock (**Locks**
below), and the fork provides the core's locks with interrupt masking
alone.

* **The source.** `erx_reserve_charge(reserve, n)` is the one source of
  pages. It charges the reserve's budget `n` pages through the core,
  which admits or refuses the charge against the budget's chain, and
  then backs them, holding a published owner's existence lock throughout
  as the kernel design requires, so that the owner's destroy drains it
  before any teardown, and no lock for an object under construction,
  which nothing but its creator reaches until it is published
  (**Construction** in [The reaper](design-kernel.md#the-reaper);
  **Thread blocks** below): in parts of at most 64 pages, under the core's released
  list lock and then its allocator lock, both ticket locks, inside which
  `Kmem_alloc::lock` is never contended, it takes what it still needs,
  free pages through the raw entry first, one page at a time
  (`Kmem_alloc::alloc(Bytes(Config::PAGE_SIZE))`: `Kmem_alloc`'s
  `Order` is a byte exponent, so `Order(0)` would ask for one byte,
  `kmem_alloc.cpp`), and then pages off the head of the released list;
  waits until Fiasco's completed batch number reaches the newest stamp
  among them; and puts them in the reserve's pool under the owner's
  lock. The wait is a poll: the backing passes preemption points
  (`Proc::preemption_point`), holding no spinlock, and reads
  `Rcu_glbl::_completed` at each, never `Context::rcu_wait`, which puts
  the thread to sleep with a state change and a callback of its own
  (`context.cpp`) and so would hold the existence lock and the hand
  across a sleep (K33). A preemption point lets the tick in, and the
  tick is where Fiasco reports a CPU's quiescent state
  (`Rcu::do_pending_work` from `Thread::handle_timer_interrupt`,
  `thread.cpp`), on a CPU with callbacks of its own and on one without,
  since `Rcu_data::pending` answers for a batch the CPU has not yet
  reported (`rcupdate.cpp`); so the batch the backing waits for
  completes once every active CPU has taken a tick after it started,
  about two ticks, and a backing's part waits at most the rest of the
  batch in progress and one whole batch, as the kernel design bounds it.
  A backing that finds its owner closed between parts fills what it has
  taken, cancels the rest through `erx_reserve_cancel` and returns
  `ERX_ESTALE`, releasing nothing itself. A charge the core refuses
  takes nothing, and that refusal, `ERX_ENOMEM`, is the funnel's only
  refusal. The raw entry returning nothing is not one: it says the free
  lists are empty, and the backing then takes from the released list,
  which the identity of B9 says is never empty at the same instant.
  `Kmem_alloc_reaper::morecore`, which Fiasco's raw entry calls on an
  empty allocator to reclaim slab pages, and the entry's out-of-memory
  warning are not built: there are no slabs to reclaim, and an empty
  allocator is the backing's case, not an error. Every page on the fork
  is a single page (**Thread blocks** below), so the identity covers
  every allocation and the allocator's splitting can strand nothing.
* **The take.** `erx_reserve_take(reserve)` moves a page from a
  reserve's pool into use, under the owner's lock, and zeroes it; it is
  the C17 function erXos's kernel runs, and the one way a page comes
  into use. A populate in `erx_user_sync_entry`'s fault path takes from
  the space's or the object's pool
  (**Faults, and the fault of the root task** below); the walk of
  `Mem_space::v_insert` and the space teardown take their tables
  through `Erx_table_alloc`, the fork's allocator adapter over the
  space's reserve, which replaces the `Kmem_q_alloc` that
  `Kmem_alloc::q_allocator` returned (`mem_space-arm.cpp`,
  `kmem_alloc.cpp`): its `alloc` is `erx_reserve_take` on the space's
  reserve and its `free` is `erx_page_release` to it, so a table that
  `v_insert` builds at a fault comes from the pool the commit backed,
  and the adapter has no rollback path, since a take never fails and
  `Insert_err_nomem` is unreachable; and the record core takes a cache
  page from the budget's own reserve. A pool is never empty when a
  committed page or its table needs one, since the core charged and
  backed one table for every region a committed mapping touches, and a
  page for every committed page (K6).
* **The release.** `erx_page_release(reserve, pages)` is the one way a
  held page's charge ends and the one way a page leaves its reserve; it
  is the C17 function erXos's kernel runs, and it is what every owner's
  teardown and `Erx_table_alloc::free` call. A teardown, a range call,
  a cache whose page holds no record and the reaper's free of a
  thread's record call it from a part that holds no spinlock, existence
  locks aside. It appends the pages the part releases to the
  machine-wide released list as one batch, chained through their page
  records and stamped by the fork's retire, under the list's lock; then
  it takes them out of the reserve's `backed` and `charged` and refunds
  their charge through `erx_budget_adjust`, in the same bounded part,
  so the budget's `used` falls, and through the chain the `lent` of
  every ancestor the pages were borrowed through, before the part
  reaches its next preemption point. A released page belongs to no
  reserve and no budget. The retire is the kernel design's
  `erx_grace_retire` over `Rcu_glbl`: under `Rcu_glbl::_lock` it stamps
  the batch `_current + 1`, sets `_next_pending` and calls
  `start_batch`, which begins that batch at once when none is in
  progress and otherwise leaves it to begin when the one in progress
  completes, in `cpu_quiet`; that is what `Rcu_data::process_callbacks`
  does for a callback it moves to its current list (`rcupdate.cpp`).
  `Rcu_glbl::_lock` is a `Spin_lock<>` (`rcupdate.cpp:125`), on the
  fork a ticket lock like every other (**Locks** below), at level 9 of
  the kernel design's lock order, since the retire takes it inside the
  released list's lock and a release holding that lock must be behind
  at most `ncpus - 1` of the tracker lock's other takers, the tick's
  quiescent-state report in `Rcu_data::check_quiescent_state` and the
  retires of the other CPUs ([Execution model and
  locking](design-kernel.md#execution-model-and-locking)). The stamp
  `_current` itself would be wrong, since a batch in progress may
  already have heard from a CPU that took a translation of the page
  after reporting, and `_current == _completed` would make the page
  mature at once. The batch's grace period has ended when the completed
  batch number (`Rcu_glbl::_completed`) reaches its stamp, which Fiasco
  advances from the tick and from idle once every active CPU has
  reported a quiescent state since the batch began; the list is in
  append order and stamps never decrease along it, so the head's period
  ends first. Fiasco compares batch numbers by signed difference
  (`Rcu_batch`), which orders a stamp correctly while no stamp on the
  list is 2^63 batches old; a batch number advances at most once per
  pass of every CPU through a quiescent state, so that age is
  unreachable within a boot, and the fork panics at the last value, as
  the kernel design's tracker does.
* **The sink.** `erx_page_free` returns a page to the buddy allocator
  (`Kmem_alloc::free`) and touches no budget. It is called from the
  reaper's free step alone, for up to 64 mature pages off the head of
  the released list, taken through `erx_released_take` under the list's
  lock and returned under the allocator's: from each CPU's idle thread
  before it waits for an interrupt, in steps with the CPU lock dropped
  between them until the head is immature, so that after such a pass
  the released list holds only batches whose period has not ended; and
  from the end of `erx_space_stop` and of capability closes, within the
  call's bound. The backing of a charge takes pages off the list
  through the same `erx_released_take` and keeps them; it is the list's
  only other caller.
* **Locks.** Stock Fiasco's `Spin_lock<Lock_t>` (`spin_lock.cpp`)
  races for ownership: `lock_arch` on AArch64 retries an exclusive
  store of a flag bit until it wins, with no order among the losers
  (`arm/64/spin_lock-arm-64.cpp:25`), so one CPU could be passed over
  for as long as the others keep winning, and a bound in steps on a
  path that takes such a lock would be no bound in time. The fork
  keeps the class, its guards and every use, and rebuilds its two
  architecture functions on the core's ticket lock, `erx_spinlock_t`
  of `kernel/core/spinlock.h`, the lock the kernel design gives every
  spinlock of erXos's kernel ([Execution model and
  locking](design-kernel.md#execution-model-and-locking)): `lock_arch`
  is `erx_spinlock_lock` and `unlock_arch` is `erx_spinlock_unlock`,
  called through the C seam as every core function is, and the lock
  word `_lock` is the core's word whatever `Lock_t` names, a 32-bit
  word of two 16-bit halves, the next ticket and the serving one. A
  taker draws the next ticket with one atomic add and waits until the
  serving half equals its ticket; a release adds one to the serving
  half with a release store; the lock is held exactly while the halves
  differ, which is what `test` and `is_locked` report. The wait loop
  and the release each use one hint from the architecture layer, `wfe`
  to wait and `sev` after the release, so the protocol is C17 and
  builds for the host, where its order is tested under
  ThreadSanitizer. A CPU holds a lock at most once and waits for at
  most one lock at a time, so a taker is behind at most `ncpus - 1`
  holders, each in one bounded critical section with interrupts
  masked; the time a part spends taking a lock is `ncpus - 1` critical
  sections of that lock, each of which may take a lock below it in the
  order, which the fork's lock-order check keeps acyclic and so keeps
  the recursion finite, and that is the lock term of every part's bound
  ([Concurrency](design-stopgap-scheduling.md#concurrency-and-failure-behavior)).
  `Spin_lock_coloc<T>`, Fiasco's lock with a pointer kept in the bits
  above its flag, keeps its value in a word of its own beside the lock
  word instead, which its two accessors, `get_unused` and `set_unused`,
  read and write; its two users, the request queues' heads
  (`Queue::Lock_n_ptr`, `queue.cpp:14`) and a context's space pointer
  (`Context::Space_n_lock`, `context.cpp:82`), use those accessors and
  nothing else, so they compile unchanged, one word larger each. The
  flag bit's name, `Arch_lock`, is deleted from the multiprocessor
  interface, so an inherited reader of the lock word's bits fails to
  compile; the tree has none outside `spin_lock.cpp` but the
  application CPUs' boot trampoline, whose assembly copy of the take,
  made because it runs before the CPU has a stack
  (`arm/64/tramp-mp.S:273`), draws a ticket the same way, and
  `App_cpu_thread` releases it through `set` as before
  (`app_cpu_thread.cpp:85`). The uniprocessor build, where `Spin_lock`
  is the CPU lock alone, is untouched. So every lock the fork takes,
  Fiasco's own and the glue's, the request queues', the ready queues',
  the priority lists', the IRQ chips', the ASID allocator's,
  `Kmem_alloc::lock` and `Rcu_glbl::_lock`, is fair by construction,
  and no path has to be audited for the locks it reaches; the funnel's
  parts reach `Kmem_alloc::lock`, never contended once the root budget
  exists, since every call of the raw entry is then under the
  allocator's lock (**Inherited allocation**, B9), and
  `Rcu_glbl::_lock`. The CPU lock is interrupt masking on one CPU, not
  a lock between CPUs, and needs no queue. What remains is the order,
  which the fork's lock-order check holds
  ([design-stopgap-scheduling.md](design-stopgap-scheduling.md#concurrency-and-failure-behavior)).
* **Grace items.** Puts, record frees and a dying thread's grace-period
  wait are retired through the same `erx_grace_retire`, which stamps
  each at its retirement, and wait on one **stamped list** per CPU,
  which the fork adds to `Rcu_data`. The item is the core's, a link, a
  stamp and a callback, embedded in the opaque header as its `rcu`
  field and in `Context` in place of Fiasco's `Rcu_item` base; it is
  appended by the CPU that queues it, under the CPU lock, in queue
  order, and stamps never decrease along the list, since `_current`
  never decreases. Fiasco's own three lists, `_n`, `_c` and `_d`, with
  `Rcu::call`, `Rcu_data::enqueue`, `move_batch`, `do_batch` and the
  `_len` count, are not built, for two reasons: `Rcu::call` appended to
  `_n`, and an item was stamped only when `process_callbacks` moved
  `_n` to `_c`, which it did once `_c` was empty, so an item queued
  while `_c` waited for a batch was stamped a batch after its
  retirement and matured up to three batches after it, past the two
  the kernel design bounds; and `do_batch` ran every callback of a
  completed batch in one loop under the CPU lock (`rcupdate.cpp:262`),
  unbounded, so a cohort of a thousand dying threads would have cost
  their CPU one masked pass over the thousand. What remains of
  `process_callbacks` is the quiescent-state report,
  `check_quiescent_state`, and the record step. The core's record
  step runs at most 64 items from the head of the stamped list whose
  stamp `_completed` has reached, in their order, each by its callback,
  a put's and a record free's the reaper's and a dying thread's
  `rcu_unblock`, which readies it on its own CPU (`context.cpp:2501`),
  and leaves the rest, which `Rcu_data::pending` and
  `Rcu::has_pending_work` report; the timer tick and the request
  interrupt each run it once (`Rcu::do_pending_work` from
  `Thread::handle_timer_interrupt`, `thread.cpp:479`, and from
  `handle_remote_requests_irq`, `thread.cpp:1299`), so the tick is the
  kernel design's reap deadline on the fork, one step per tick, and a
  mature item runs within its grace period, fewer than two batches
  after its retirement, plus the ticks its CPU's backlog needs, one per
  64 items queued ahead of it. `~Rcu_data`, which moved an offlined
  CPU's three lists to the current CPU's, has nothing to move and no
  caller: `take_cpu_offline` is reached only from the x86 sleep code
  (`platform_control-acpi_sleep.cpp`), and the fork takes no CPU
  offline. `Context::enter_tickless_idle` runs nothing: it refuses
  tickless idle while `Rcu::has_pending_work` holds, a non-empty
  stamped list included (`context.cpp`), and the fork's idle thread
  runs steps, with the CPU lock dropped between them, until no list
  has work before it enters idle, as the kernel design's idle thread
  does. Of stock Fiasco's three callers of `Context::rcu_wait`, the
  sleep until the next grace period, the fork keeps one, `do_kill`'s
  (`thread.cpp:633`), bounded as the scheduling binding states ([Death
  and the death edge](design-stopgap-scheduling.md#stop-and-exit)).
  `Reap_list::del`'s (`kobject.cpp:231`) is not built, since a deletion
  queues its put; and `Ipc_gate::bind_thread`'s (`ipc_gate.cpp:338`),
  which let a sender that had read the old binding without a lock
  finish blocking before a second `unblock_all`, is not built either,
  since the fork writes a gate's binding and wakes its blocked senders
  under the gate's lock, where no such window exists. No charge depends
  on when any item runs.
* **Page records.** The released list and the reserves' pools chain
  pages through their page records, as on erXos's kernel ([Virtual
  memory](design-kernel.md#virtual-memory)); Fiasco has none, its buddy
  allocator keeping only a free map. The fork adds an array of the
  core's page records, 16 bytes each, the owner, a page-index link, the
  count and the flags, one for every page of the span from the lowest
  heap address to the highest, holes included, indexed by the page's
  offset from the span's base. The array cannot come from the raw
  entry: `Buddy_alloc` is `Buddy_t_base<10, 11>`, so one block is at
  most 1 MiB (`buddy_alloc.cpp`), and a 512 MiB heap needs 2 MiB of
  records. `Kmem_alloc`'s constructor carves it instead, before it hands
  the heap's regions to the buddy allocator (`add_mem`,
  `kmem_alloc.cpp`): it takes the whole pages the records need from the
  top of the highest region, so the allocator never sees them, and that
  carve is `boot_reserve`'s per-heap-page term, outside the root
  budget's identity as every boot carve-out is. The
  link lives in the record, never in the page: nothing writes a page
  between its release and its free, which is what the grace period is
  for, and a pooled page is zeroed only when it is taken into use.
* **The boot allocator.** Before the root budget exists Fiasco's boot
  takes from the raw entry directly, bounded by `boot_reserve`
  (**Kernel memory and the root budget** below). The slab layer is not
  built: `Kmem_slab`, `Slab_cache` and every `Kmem_slab_t<>` cache,
  which charge an entry's size and draw backing pages uncharged
  (`kmem_slab.cpp`, `slab_cache.cpp`), and `Ram_quota`'s byte charge
  leave the fork's sources, and each object's `operator new` is the
  record core below. So an inherited callee that still allocates from a
  slab, however deep below the glue, fails the link, with no list of
  callees to keep; the FP state's slab (`fpu_alloc.cpp`) was one such
  callee, and its storage is inline in the thread block (**FP and SIMD
  state** above). What remains is the page allocator, whose raw entries
  (`Kmem_alloc::alloc`, `Kmem_alloc::free` and their order-taking forms)
  are marked `noinline` in the fork so that every call site is visible
  in the linked kernel: the call-site check of [Interfaces](#interfaces)
  requires each to be in the funnel, in the free step or in a boot-time
  function listed in `fiasco/erx_boot_allocators.txt`, and each listed
  function to be in an initialization section, so that what boot takes
  is taken before the root budget exists and is bounded by
  `boot_reserve`.
* **Records.** Kernel records come from the C17 slab core,
  `kernel/core/kalloc.c`: each budget has, per record kind, a list of
  cache pages from the budget's own reserve, charged and backed a page
  at a time in the call that needs the record, each page's header
  naming the budget and kind; a record is carved from a page of its
  budget, and a page that holds no record is released through
  `erx_page_release`. A budget thus pays for its own fragmentation, and
  no cache is shared between budgets. A record's cache page stays
  charged through the record's grace period and its last counted
  reference, since a record is memory a call in progress may read: the
  slot returns to the cache from the reaper's record free, and the page
  is released when that free leaves it empty, as the kernel design's
  rule says. What that keeps from a budget is what the kernel design
  bounds: the cache pages whose every record its tree destroyed, kernel
  records alone, for their grace period and the ticks their CPU's
  backlog needs, one per 64 records queued ahead of them, when no call
  holds those records counted, and otherwise until the holding calls
  run ([Security](design-kernel.md#security)).
* **Owners.** Every held page is reachable from exactly one reserve and
  its owner's record: a cache page from its budget's reserve; a
  thread's two block pages and its kernel-user page from the thread's;
  a translation table, a capability-table page and a private page from
  the space's, in its pool until a fault or `Mem_space::v_insert` puts
  it in use; a memory object's pages from the object's. The owner's
  teardown releases the pages through `erx_page_release`, pooled and in
  use alike, and only the free step or a backing takes them off the
  list.
* **Thread blocks.** Fiasco finds the running thread by masking a stack
  address with the block size: `Context_base::Size` is
  `THREAD_BLOCK_SIZE`, 8 KiB under `CONFIG_CONTEXT_8K`, the automatic
  choice on 64-bit targets (`kern/config_tcbsize.h`, `src/Kconfig`);
  `context_of` masks with it (`kern/context_base.cpp`), the entry
  code's `CONTEXT_OF` does the same (`kern/arm/64/ivt.S`), and
  `Thread_object::create` takes `Thread::Size` from the allocator in
  one piece (`kern/thread_object.cpp`). So a block must be 8 KiB and
  aligned to 8 KiB in the kernel's virtual addresses, and nothing
  requires it to be contiguous in physical memory. Fiasco takes it as
  one order-1 block of the buddy allocator, which is where an
  accounting in pages would break: a charge of two pages is admitted
  against pages, but the allocator has an order-1 block free only
  while two buddies are both free, so a domain that commits a run of
  pages and releases every other one leaves free pages with no order-1
  block among them, and a thread creation admitted on its charge would
  find no block, on another domain's fragmentation, with no released
  page to wait for. The fork therefore does what erXos's kernel does
  with its stacks, which live in a slot region page by page
  ([Threads](design-kernel.md#threads)): a thread block is two single
  pages, which `erx_thread_create` charges and backs through
  `erx_reserve_charge` into a reserve on its own frames, the
  construction case of the kernel design, because the thread's record,
  which holds the thread's reserve, is the block itself and exists only
  once its pages do: `Thread_object::create` allocates the storage and
  then constructs the object in it (`thread_object.cpp`). Once the
  block is mapped and the object constructed, the object takes the
  reserve over, and the creation publishes the thread by its inserts,
  onto its budget's `att_charged`, into its task's thread list under
  the task's lock, and into the creator's table; a refused insert destroys
  the unpublished thread through the ordinary deletion walk, which
  releases the block (**Construction** in [The
  reaper](design-kernel.md#the-reaper)). The two pages are mapped
  into an 8 KiB-aligned
  slot of the **thread region**, a range of the fork's kernel virtual
  layout, with page entries in the kernel directory written as
  `Kmem_alloc::map_pmem` writes superpage ones (`Kmem::kdir->walk`,
  `kmem_alloc-arm.cpp`). The region is `Thread_region_start` to
  `Thread_region_end`, `0xffff0000'c0000000` to `0xffff0001'00000000`,
  two constants the fork adds to `Virt_layout_kern` of the
  non-hypervisor layout in `arm/64/mem_layout-arm-64.cpp`, the one
  layout the fork builds (`CONFIG_CPU_VIRT` unset, pinned by the
  configuration check): 1 GiB, as large as the physical-memory window
  it mirrors slot for page pair, starting 1 GiB above `Map_base`, which
  is where that layout maps the kernel image (`Pmem_end` and `Map_base`
  are the same address there), and ending below the debugger's service
  area at `0xffff1000'eac00000`. Two `static_assert`s in the glue pin
  it against the layout, that it ends at or below `Tbuf_status_page`
  and is as long as `Pmem_end - Pmem_start`, and an `ASSERT` in the
  fork's kernel linker script pins it against the image, that
  `_initcall_end`, the end of the range `add_initial_pmem` registers,
  lies below `Thread_region_start`; a layout or image change that
  crosses any of them fails the build. The region has one slot per two
  pages of the heap, and its translation tables are built at boot,
  within `boot_reserve`'s per-heap-page term; a free slot is found in a
  bitmap under a leaf lock. A creation that holds its two
  pages always finds a slot: a slot is taken only after its block's two
  pages are held and returned before they are released, so the slots in
  use never exceed half the pages held; the creation's own two are held
  and not yet in a slot, and held pages never exceed the heap's, so the
  slots in use are fewer than the slots. `context_of` and
  `CONTEXT_OF` are unchanged, since the slot is aligned, and the glue's
  `static_assert` that the record with its FP state leaves the block
  the stack allowance stands. The block is the thread's record, and
  goes as a record's cache page does: the reaper's free of the record,
  at zero references after the thread's grace period, when no CPU can
  be on its stack, clears the slot's two entries in the kernel
  directory, invalidates them on every CPU (`Mem_unit::tlb_flush_kernel`
  by address, `arm/64/mem_unit-arm-64.cpp`), returns the slot, and then
  releases the two pages through `erx_page_release`; the pages reach
  the free lists after their own grace period, as every released page
  does.
  So every page on the fork is a single page, the identity of B9 covers
  thread blocks as it covers data pages, and a thread creation whose
  charge is admitted never fails for a block. The boot CPU's and the
  secondary CPUs' kernel threads
  (`Kernel_thread::create_for_boot_cpu`, `App_cpu_thread::may_be_create`)
  are created before the root budget exists, from the raw entry within
  `boot_reserve`, as 8 KiB blocks of the window, aligned by the buddy
  allocator and never freed; `context_of` serves them as it serves a
  slot.
* **The kernel-user page.** Fiasco's `Task::alloc_ku_mem` charges the
  task and keeps the page on the task's list (`task.cpp`); the fork does
  not use it. The thread's kernel-user page is the third page of the
  thread's reserve, charged and backed when the thread is created,
  mapped by a mapping record of kind `ERX_MAP_KERNEL` in the space, and
  released by the thread's teardown after that mapping is removed and
  its invalidation has completed; the space's teardown finds no such
  page of its own.

The core alone decides whether a charge fits, and the core alone moves
a page between a reserve's pool, use, a backing's hand, the released
list and the free lists. The mechanism gives it the raw page source and
sink, interrupt masking for the core's ticket locks, the RCU batch
numbers with the request of the next batch, the page records and the
owner record of every page; the kinds, caps, borrowing, resizing and
the watch are the core's, so a change of budget policy changes nothing
here.

### Rights by creation kind

Rights are built by two functions and nothing else:

```c
erx_rights_t	erx_rights_create(erx_create_kind_t kind);
erx_rights_t	erx_rights_shrink(erx_rights_t rights, uint32_t mask);
```

`erx_create_kind_t` is a closed enumeration with one value for each row
of the two tables of [Rights](design-kernel.md#rights): the root budget,
whose capability carries no `DESTROY`, and a carved budget, which
carries it; the space, the thread, the group, the gate; each memory kind
(shared, physical, contiguous, JIT, paged, paged with code, copy-on-write
child, the boot image, a slice, the time page, the machine page, the
device-secret page, the previous crash record); each IRQ kind (software,
line, MSI); the root resource, a carved resource, and a DMA window. The
ABI file declares the table of default rights per kind, and the
generator emits `erx_rights_create` as a lookup over it and checks that
each kind's set lies within its type's carryable set and that each carve
root holds every right of its carving but `DESTROY`. A creation's pure
plan produces the kind from the validated arguments (the flags of
`erx_mem_create`, the `ERX_MEM_CODE` flag of a paged object, the kind
argument of `erx_irq_create`), the boot step produces the root kinds, and
the install takes the kind, so no creation can ask for a union of two
kinds' rights. A carve is a shrink of a create:
`erx_rights_shrink(erx_rights_create(kind), through.bits |
ERX_HR_DESTROY)`.

### Boot handoff

The production module recipe lists `bootstrap` and one module, the boot
image. `bootstrap`'s one erXos function, called before any inherited
module handling, and the only module handling the fork's `bootstrap`
builds:

1. opens the module's bytes with `erx_pack_open`, the C17 validator of
   `kernel/core/pack.c` linked into `bootstrap`, with its scratch in
   `bootstrap`'s own data, and stops with the validator's reason on a
   failure, so no byte of a refused image is ever copied or run;
2. finds the kernel by the one path the ABI file fixes
   (`boot_kernel_path`, under `boot/`, which the root task never names),
   an entry of kind `file`, and the root task by the header's
   `root_entry`, which the validator has already checked to be an
   executable image;
3. plans the kernel's placement with `erx_elf_plan` in its kernel
   profile over the entry's bytes, which yields the loadable segments
   and the two metadata views, and `erx_boot_place` over the memory
   map, with the archive, `bootstrap`'s own image and the device tree
   as reservations the plan may not touch and the archive's rounded
   extent kept clear of the kernel's, and stops with the plan's reason
   on a failure;
4. reserves, in the inherited region table, the whole archive first,
   page-aligned and unmoved, as a region that enters the kernel's memory
   descriptors as bootloader memory, then the kernel's placed segments,
   then copies each segment from its source range inside the archive to
   its placed range, zero-filling the rest, and cleans the caches as the
   inherited loader did; the archive's bytes are never released, since
   the source region stays reserved; the root task is not placed, since
   the kernel maps it from the startup plan;
5. runs `erx_pool_plan` over the memory map and the reservations, writes
   `heap / 1024` as `kmemsize` into Fiasco's options and `usable`,
   `heap` and `regions` into the handoff record;
6. copies `/chosen/bootargs` from the device tree, cut at the last whole
   word within `boot_strings_max`, and fills the handoff record with the
   image's flags and build identifier, the archive's address and size,
   and the arguments; checks that the information-page view, now
   copied, starts with Fiasco's page magic, and writes the kernel's
   memory descriptors into that view and the options block into the
   options view, each within the view's size; and jumps to the plan's
   entry.

Fiasco's `exec_load_elf`, `load_elf_module`, `find_kip` and the module
region subtraction are not built into the fork's `bootstrap`.

The kernel reads the record at its start, checks the version, checks
that a bootloader descriptor covers the archive, checks the device
tree's memory against the manifest's `memory_min`, parses the `erx.`
keys of `bootargs` as [Configuration](design-kernel.md#configuration)
says, and keeps the rest for the machine page. Fiasco's own options stay
on the kernel's module line in the recipe. The banner prints the build
identifier and `development build: trusted code only` when the flags say
so, after Fiasco's start-up lines and before the root task starts.

### Kernel memory and the root budget

Fiasco's kernel allocator takes `kmemsize` from the options block when
it is set (`Kmem_alloc::determine_kmem_alloc_size`), rounds it up to its
superpage, and carves that much from the top of its free map, which it
builds from the kernel's memory descriptors with conventional memory
rounded inward and every reservation rounded outward to the superpage
(`create_free_map`); it maps each heap region into the physical-memory
window with superpage entries (`kmem_alloc-arm.cpp`), and
`phys_to_pmem` answers for nothing else (`mem_layout-arm.cpp`). So
subtracting byte sizes cannot predict the pool: `erx_pool_plan` does the
same rounding and the same top-down selection, and its `heap`, as
`kmemsize` in KiB, is what `bootstrap` passes, never more than the free
map holds, so the allocator's panic on an unfillable request is
unreachable from a plan that passed.

At its start the kernel runs the same plan over the descriptors it was
given and the reservations it knows, and refuses to go on, with a crash
record of cause `PANIC` naming both figures, if its `heap` or `regions`
differ from the handoff's: the plan is recomputed, never trusted. It
then maps the archive's rounded reservation into the window beside the
heap, read-only (`Mem_layout::add_pmem` and superpage entries, as the
heap is mapped), so that the root planner can read the manifest and
`erx_image_map` can copy the writable segments through `phys_to_pmem`;
the plan's window check made room for it, and the placement plan kept
its rounded extent clear of the kernel image's region. Memory beyond
the window is unusable on the stopgap, a limitation the harness
respects by pinning guests at 512 MiB. Memory objects' pages,
kernel-user pages, kernel stacks, records and translation tables all
come from the heap, through the funnel.

The **root budget**'s guarantee and cap are one figure, as the kernel
design makes them ([Budgets](design-kernel.md#budgets)): what the heap
holds free at the moment the kernel creates it, after Fiasco's own boot,
read from the allocator's free map, a verified figure, not `bootstrap`'s
report. The root is a wall that borrows from no one, and its guarantee
is the right-hand side of B9's identity: pages held plus pages in
backings' hands plus pages released plus pages free is that figure
from then on. The kernel checks it
against the model: `free >= heap - boot_reserve(cpus, heap)`, and a
shortfall refuses to start the root task with a crash record of cause
`PANIC` that names both figures, so the bound the packer admitted
against is enforced where it matters. Every other budget is carved from
the root by the root task and the domain library, walls for principals,
domains and pools and elastic budgets for programs, and the manifest's
`root_memory` is the guarantee the root task requires of the root
budget at its entry before it carves anything
([design-system.md](design-system.md#resource-policy)).

### The startup plan and its charge evidence

Each plan is one pure function that runs on the host, at packing, and
in the kernel, at boot; the two runs do not see the same inputs, and
the kernel checks a stated relation between them.

* The root plan's inputs are the root entry's manifest and the charge
  model, the same bytes on both sides, so its two results are equal:
  the kernel requires the charges it applied to equal the plan it
  computed, and the host's `total` is that same figure.
* The pool plan's inputs on the host are the platform's memory table at
  `memory_min` and bounds on the reservations: the kernel's placed
  extent, which the link fixes; the archive's size; and
  `loader_reserve` for what the loader places, whose addresses the host
  cannot know. At boot its inputs are the actual descriptors and the
  actual reservations. The relation is monotone: more RAM and smaller
  reservations never shrink `heap`, because the region limit refuses a
  map rather than choosing within it (**The pool plan**), which a host
  test of the plan pins, so with RAM at least `memory_min`, each loader
  reservation within `loader_reserve` and the free map within the
  region limit, all three checked at boot, the kernel's `heap` is at
  least the host's. `bootstrap` and the kernel, which do see the same
  inputs, must agree exactly.

**On the host.** The packer runs `erx_root_plan`, built for the host and
called through a small host helper as `erx_dom_plan_create` is for
property 12 ([design-abi.md](design-abi.md#canonical-source-packing-and-checking)),
over the root entry's manifest and the backend's charge model, and
`erx_pool_plan` over the platform's memory table, with the kernel's
placed extent from `erx_elf_plan`'s kernel profile over the kernel it is
packing, the archive's size and `loader_reserve` as the reservations. It
admits the image only if

```text
pool.heap - boot_reserve(cpus_max, pool.heap) - plan.total >= root_memory
```

where `pool.heap` is the pool plan's heap at `memory_min`, the
smallest RAM the manifest's platform record admits, which the packer
writes from the platform table and the kernel checks against the device
tree at boot; `cpus_max` the platform's CPU count; and `root_memory` the
manifest's, the guarantee the root task requires of the root budget
after the root plan's charges. `usable` is not the figure: the heap is what the allocator
holds, and `usable` exceeds it by whatever the window or the region
limit cut. The admission records the plan's `total` and step counts,
the pool plan's figures, the model's identity (backend, the ABI's
generated-output hash, the kernel build it was asserted against) and the
inequality's figures as the **charge evidence** inside the `Admitted`
value that the publisher requires (`tools/lib/erx/manifest.rb`). Only
the production plans produce that value: a cost declared in a source
file or a structural test fixture is not evidence and admits nothing.
The kernel repeats both computations at boot; the host's figures are a
prediction it checks, never an input.

**At boot.** The kernel's boot step for the root task runs `erx_root_plan`
over the same manifest, read from the archive's alias, applies each
step through the funnel, charged to the root budget, maps the image's
read-only and executable segments from the boot image's object and
copies its writable segments into private pages, as `erx_image_map`
does, builds the capability table with the root slots the ABI file
fixes, writes the boot information page and the machine page, creates
the first thread as a worker of `system` with the plan's start
registers, and before it starts the thread compares the root budget's
`used` and the count of each record kind with the plan. A difference is
a kernel bug and refuses the start with a crash record of cause `PANIC`
naming the step. Fiasco's `init_std_workload` (`std_workload.cpp`),
which starts a `sigma0` thread, requires a root entry in the
information page, installs Fiasco's initial capabilities and a pager
gate, is not built; the fork's workload step creates the `sigma0` task
and runs the plan. Fiasco maps a boot task's bootloader memory itself
only in its MPU configuration (`Task::map_all_segs` in
`arm/task-arm.cpp`); in the fork's MMU configuration that function is
empty (`task.cpp`), so the plan's mapping steps, through the erXos
mapping records, are the only thing that maps the root task's image,
charged and with a ceiling and a reverse map like any other mapping,
and the root task needs no pager (below).

**What M1 admits.** Production native partial boots, the empty one
included: the root plan is required for every image, and `erx_dom_plan_create`
for each child the manifest names. A manifest whose configured domains
need a consumer the tree does not have (ERTS, a service) fails to pack
as unsupported, with the property number, as [plan.md](plan.md#m0-the-tree-the-toolchain-and-the-oracle)
requires; nothing weakens that path.

### Faults, and the fault of the root task

`erx_user_sync_entry` hands every memory fault to `erx_fault_decide`
over the task's erXos mapping records under the mapping's object lock
([Virtual memory](design-kernel.md#virtual-memory)). A populate result
takes its page from the space's or the object's pool through
`erx_reserve_take`, never from the allocator, inserts the translation
through Fiasco's `Mem_space::v_insert`, whose table allocator draws on
the space's pool as well (**Budgets and the ownership of pages**), and
applies `erx_tlb_plan`'s invalidations through `Mem_unit`; a fault
record stops the thread and is delivered to the space's fault gate as a
kernel-originated message with the space's fault label, queued at the
gate's thread as Fiasco queues an IRQ delivery (`Irq_sender`), at
`ERX_URGENCY_MAX`. The pager and exception-handler fields of Fiasco's
thread stay `Thread_ptr::Invalid` for every thread: no path calls
`Thread::control` to set them, and the paths that read them are not
built, so no code in a space can redirect its faults.

**The root space** is the one space without a parent: the root plan
creates it so, and `erx_space_create` always records the caller's space
as the parent, so no other space is ever without one, and nothing can
take the root's parent away. That identity, not the absence of a fault
gate, routes the root's faults: a fault record whose space has no parent
reaches `erx_panic` with cause `FAULT` and the record, writes the crash
record and ends the machine (K31), and the root's halt outside
`erx_machine_end` goes the same way. An ordinary space whose fault gate
is gone, because the gate was destroyed or released
([Threads and faults](design-kernel.md#threads-and-faults)), keeps the
specified behaviour: the thread stays stopped, and the record is dropped
and counted in the space's inspection; a parent that destroys its
child's gate and then provokes a fault in the child stops one thread
and nothing more. The root task runs without a pager: the only
consequence a missing pager has in Fiasco is that
`handle_page_fault_pager` kills the faulting thread, and that function
is not built. The image is mapped whole by the plan, so a root fault is
a bug or an attack, never a page to fetch.

### IPC gates, and where transfer fits

The IPC core, `erx_ipc_step`, decides sends, receives, replies and
deadlines; the glue carries them on Fiasco's paths: `Ipc_gate` binding
with a 64-bit label in place of Fiasco's label with rights bits; the
sender lists ordered by urgency and arrival (`prio_list.cpp`), whose
insert on the thread's home CPU refuses a thread marked dying with
`ERX_EDEAD`, as it refuses a closed one, so no sender queues after the
thread's drain; the handshake that moves the receiver into
`Thread_ipc_transfer` (`handshake_receiver`); the sender performing the
transfer, by `erx_msg_copy`, and ending it with one request to the
receiver's home CPU (`activate_ipc_partner`, which only makes the
receiver ready and switches to nothing); the implicit reply capability
as the caller; and absolute deadlines as Fiasco timeouts armed from the
decoded kernel-clock values. There is no direct switch: the scheduler
picks the receiver at the sender's next decision, as
[design-stopgap-scheduling.md](design-stopgap-scheduling.md#server-urgency-and-charging)
binds it.

**Waits and cross-CPU requests.** The glue's three sleeps,
`do_send_wait`, `do_receive_wait` and `Ipc_gate::block`, the sender's
wait at a gate bound to no thread, sleep through the scheduling
binding's one wait funnel, `Erx::wait_sleep`, whose decision is the C17
`erx_wait_step`, and are ended through `erx_wait_complete`, so a thread
of a stopped space cannot sleep in an IPC wait, and the stop cancels no
list of IPC wait kinds. `Ipc_gate::invoke` reads the gate's binding
once, before its block; a sender woken at a gate bound to no thread
returns the dispatch's retry action and starts its send over from its
capability, so a gate deleted between the wake and the resume is never
read, and Fiasco's unblocked queue (`_unblocked_q`, `ipc_gate.cpp:154`)
and its second read of `_thread` after the block (`ipc_gate.cpp:489`)
are not built ([After the resume, a fresh
lookup](design-stopgap-scheduling.md#the-wait-funnel)). Every cross-CPU
request the glue sends, the handshake, the reply and the abort, is
eager (`Context::drq` with `eager = true`), run in the inter-processor
interrupt's handler on the receiver's CPU whatever runs there. Fiasco
sends the handshake eagerly only when the receiver looks ready
(`thread-ipc.cpp:1462-1467`) and the abort never eagerly
(`receiver.cpp:754`), so a sender's wait for its answer, which it cannot
cancel, lasts until the receiver is scheduled; a hostile domain that
keeps the receiver's CPU busy would hold the sender, and with it its
space's exit record, forever (ST6 of
[design-stopgap-scheduling.md](design-stopgap-scheduling.md#requirements)).
The cost is one inter-processor interrupt per cross-CPU send to a
receiver that is not ready, which the `ipc` benchmark measures in its
cross-space row pinned to another CPU
([Observation](#observation-ends-the-pet-stop-hook-and-the-benchmarks)).

**Where transfer fits.** The transfer has one install point: under the
receiver's table lock, after the receiver is held in its transfer and
the words have moved, where `erx_pass_apply` fills the slots the
receiver's wait reserved ([Passing capabilities](design-kernel.md#passing-capabilities)).
M1's binding already runs the reservation step of every receive, with a
buffer descriptor that asks for zero slots, and already has the install
point, where it installs nothing; a message whose tag names items is
refused with `ERX_EINVAL` in M1. M5 lifts that refusal and runs
`erx_pass_plan` before the install and `erx_pass_apply` at it, under
the ownership of a transfer with items that M5's design must fix
first: the step that holds the receiver must stay one bounded step that
no sender's scheduling controls, which Fiasco's item transfer in the
sender's context does not give
([Transfer ownership](design-stopgap-scheduling.md#stop-and-exit)).
Whether the handshake and the request that ends the transfer stay as
M1 has them follows from that design.

**Executors.** Every IPC call that may wait is refused to an executor
by the generated dispatch with `ERX_EWOULDBLOCK`, as is `erx_space_stop`,
marked `executor: refuse`. `erx_ipc_reply` does
not wait and is not refused by class: an executor never receives, so it
never has a caller, and its reply fails with `ERX_ENOCALLER` like any
reply with no caller. The conformance suite checks both.

### Stop and exit: the binding

[design-stopgap-scheduling.md](design-stopgap-scheduling.md#stop-and-exit)
binds K18 on the fork: the run word with its live count, the one request
to each thread, the return check in the common return path, the kill
continuation, the finishing priority and the exit record. This document fixes
what that binding can rely on: every wake out of a wait returns through
the call's C++ frames (the IRQ shortcut is off), every thread's first
entry and every call's return leave through Fiasco's common return path,
and the vCPU return (`__iret`) is not built until M5. `erx_thread_stop`,
`erx_thread_start`, `erx_thread_read`, `erx_thread_write` and a thread's
destroy reach the thread only through `Erx::thread_request`, the
binding's one request to a thread's home CPU, so no call touches a
thread's state or registers from another CPU. The stopper's wait for
`EXITED` is a stopper's wait of the binding's wait funnel,
`Erx::wait_sleep`, ended through `erx_wait_complete` either by the
death that publishes `EXITED` or by the stopper's own kill, which is
what lets two spaces stop each other (ST7 and the wait classes of
[design-stopgap-scheduling.md](design-stopgap-scheduling.md#stop-and-exit));
nothing is counted, and the fork adds no thread-state bit for it. The
exit record's cross-CPU delivery is an `Erx::request` naming the space.

**What this binding requires of the scheduling binding.** Three
interface constraints follow from the constructions above, and the
scheduling binding meets them:

* *Queued requests at a dying thread.* A request queued at a thread
  through `Erx::request` holds a reference on the object it names, not
  on the thread, whose own queue holds it. The kill continuation
  therefore closes the thread's queue first, writing the dead mark
  under the queue's lock, after which `Erx::request` refuses the thread
  and takes nothing, and then runs every request the queue holds, or
  cancels it by dropping its reference, in parts of at most
  `ERX_REQUEST_BATCH` steps with a preemption point between them,
  before `unbind()`; so the drain is of the cohort the mark closed and
  no other CPU can lengthen it. A delivery refused at the mark stays
  its sender's, who resolves the object's binding again. Every entry
  that drains request queues has one budget for the whole entry, as
  the scheduling binding specifies. A request that
  waits (`Erx::thread_request`,
  `Context::drq`) names only its waiting requester and its target and
  needs no such step.
* *Order between an eager abort and a queued delivery.* The abort may
  run first; the delivery's handler decides from the binding it reads
  under the IRQ lock, never from the order.
* *No FP step at teardown.* The thread's FP state is inline in its
  block, so the kill continuation frees nothing for it and
  `release_fpu_if_owner` is the eager implementation's empty one; a
  finishing thread runs on its own CPU, so a stop moves no FP state
  between threads.

### Park and wake: the binding

[design-stopgap-scheduling.md](design-stopgap-scheduling.md#park-and-wake)
binds the park protocol of [design-scheduler.md](design-scheduler.md#park-and-wake)
on the fork. An IRQ object bound to a group takes the C17 ready-list step
in `Irq`'s hit path, and a wake of a thread out of `erx_park` returns
through its frames like any other wake.

### Server urgency and charging: the binding

[design-stopgap-scheduling.md](design-stopgap-scheduling.md#server-urgency-and-charging)
binds configuration C0's urgency ceilings (S5), the absence of a direct
switch (a send makes the receiver ready and switches to nothing, and the
scheduler picks it with its own scheduling context) and the tick's
charging on the fork.

### The watchdog, the crash record and the console

**The watchdog.** `erx_watchdog_step` is driven by three events: the
root task's start, from the boot step that starts its first thread; a
pet, from `erx_watchdog_pet`'s handler, which the generated decoder
admits only with `POWER` on the root resource; and a tick, from the
fork's tick hook on the boot CPU, once a second. Its end action calls
`erx_panic` with cause `WATCHDOG`. In deterministic mode the step is off
and the machine page says so.

**`erx_panic`** on the fork is the one funnel of every end that is not
`erx_machine_end`: the root space's fault, its halt outside an ordered
shutdown, a missed deadline, and a kernel panic, into which Fiasco's own
`panic` and assertion failures are routed first, with cause `PANIC`. It
sets the panic word, stops the other CPUs with Fiasco's IPI, writes the
crash record into a static buffer of the kernel image (QEMU has no
region that survives a reset), prints the report and then the crash
frame on Fiasco's kernel UART, the early console, and ends as
`erx.panic` says through `erx_machine_end_effect`, which alone calls
`Platform_control::system_off` and `system_reboot` (PSCI) or halts. The
development build's debugger, when present, is entered only after the
frame is complete.

**The crash frame's transport.** The frame itself, its header line, its
line length, the exact length each form admits and every check the
reader makes, is the kernel design's
([The root task](design-kernel.md#the-root-task)); the stopgap only
carries it. `erx_crash_frame_write`, a C17 function with no allocation,
writes it on Fiasco's UART driver for the early console through the
console effect, line by line, after the report and after every other
CPU has stopped, so no other output interleaves with it; the UART's
bounded poll for room applies to every byte, so a hung UART drops the
rest of the frame, which the reader then reports as truncated. The
harness's reader, `tools/lib/erx/crash_frame.rb`, takes the first
header line after the banner from the serial log and validates as the
kernel design says; the reader and the writer share a fuzz target over
both forms.

**Console ownership in a partial boot.** The early console prints every
kernel log record, `erx_debug_log` lines included, until the system
domain's console driver takes the UART. Who writes is one C17 decision,
`erx_console_owner_step`, over two states, kernel and driver, and three
events: the first `erx_resource_carve` of the console UART's device
entry from the root resource, which the device service makes when it
gives the UART to the console service, moves the owner to the driver; a
carve of any other entry changes nothing; a panic or the machine's end
writes whoever owns it. A partial boot never carves the entry, so its
programs' log lines reach the console for the whole run, and nothing is
keyed on time or on a flag. M1 has no device resources to carve, so the
driver's half of the step is host-tested, and its QEMU case lands with
the resource rows' milestone.

### Observation: ends, the pet-stop hook and the benchmarks

**The guest's own end.** Under `-no-reboot`, a PSCI `SYSTEM_OFF` or
`SYSTEM_RESET` exits QEMU. A transcript plan may declare `ends: guest`,
under which the harness does not terminate QEMU when the checkpoints
are complete but waits for its exit within the deadline, and reports
`guest_end`: `self` when QEMU exited by itself with status zero and the
serial log's last line is the kernel's end line, which
`erx_machine_end_effect` prints before the firmware call, naming the
cause and `how`; `killed` when the harness's deadline ended it; and
`timed_out` or `failed` otherwise. The K31 cases run with
`erx.panic=off`, so each end is a `self` exit with its crash frame
before it; one further case runs with `erx.panic=halt` and expects the
frame followed by silence until the deadline kill, reported as
`killed`.

**The pet-stop hook.** A kernel built with the conformance image's test
hooks accepts `erx.test.drop_pets_after=S`: after `S` seconds of
uptime the watchdog core receives no pet event, while `erx_watchdog_pet`
still returns `ERX_OK`, so the root task cannot tell and the deadline
passes as it would under a hang. The key's parser is compiled only into
test-hook builds; an ordinary build reports it as an unknown `erx.` key
and runs on, and a test boots one with the key and requires no end.

**Benchmark endpoints** (gate G1), each a workload in the conformance
image that reports `erx-bench <name> <key>=<value>...` on the console,
timed by the time page's counter, and recorded by `tools/erx bench
<name>` with host, accelerator, QEMU version, compiler, flags, workload
and baseline, TCG apart from HVF:

| Name | Workload | Endpoint |
| --- | --- | --- |
| `null` | `erx_thread_set_urgency(ERX_CAP_SELF_THREAD, u)` with `u` the thread's current base: decode, one lookup, a decision that changes nothing | the call's return; Fiasco's native null call (29 ns under HVF) is the baseline |
| `ipc` | a worker's `erx_ipc_call` to a server in `erx_ipc_reply_wait`; same space and a sub-space; same CPU and pinned to another | the caller's return |
| `park` | an executor in `erx_park`; a worker triggers an IRQ object bound to the group; same CPU and another | the executor's return from `erx_park` |
| `timer` | `erx_park` and `erx_ipc_wait` with a deadline | the return, against the deadline: **deadline-to-resume latency**, which includes the tick's quantisation and the scheduling delay |
| `boot` | the harness's clock from QEMU's start to the root task's banner line, and the kernel's own uptime printed on that line | the root task's first instruction |
| `stop` | `erx_space_stop` of a space whose threads are inside long range calls and in waits on every CPU, and of a tree | the stop's return and the exit record |

M1 has no device line a workload can program, since physical objects
from device resources come later, so `timer`'s deadline-to-resume
latency is M1's figure; it is not an interrupt-latency claim, which
needs an interrupt-entry timestamp. A hardware line's latency is
measured with `tools/erx bench irq` when resources land.

## Interfaces

* **`fiasco/kernel/src/erx/`**, the glue: `entry.cpp` (`erx_user_sync_entry`,
  `erx_user_serror_entry` and `erx_syscall`), `object.cpp` (the header,
  `Erx::kobject`, the installers, the lock effects), `request.cpp`
  (`Erx::request`, the one queue of a request its requester does not
  wait for), `space.cpp`, `thread.cpp` (the admitted register record,
  `Erx::regs_load`, `user_invoke` and the thread region's slots),
  `budget.cpp` (the funnel, the page records and the page effects),
  `group.cpp`, `memory.cpp`, `gate.cpp`, `irq.cpp`,
  `resource.cpp`, `fault.cpp`, `boot.cpp` (the handoff, the pool check,
  the archive alias, the workload step, the root plan's application),
  `panic.cpp`, `effects.cpp` (every other `erx_effect_*`), and
  `charges.cpp` (the `static_assert`s). Each file is erXos's own C++ in
  Fiasco's preprocessor dialect.
* **`include/erx/core/`**, the seam: one header per core with its opaque
  types and exported functions, `object.h` with the embeddable opaque
  header, and `effects.h`, the prototypes of the effects a host of the
  cores provides: the raw page source and sink, interrupt masking for
  the core's ticket locks, the RCU batch numbers and the request of the
  next batch, the page records, translation-entry writes and
  TLB maintenance, the lock operations, readying and requesting a CPU,
  arming a timeout, the console writer, the firmware's end. Record
  definitions are in `kernel/core/*_impl.h`, which only the cores
  include.
* **`fiasco/erx_glue_imports.txt`**: every Fiasco internal the glue may
  reference, one per line with the effect that calls it and the glue
  file that may hold the call. It is an allowlist: a glue object whose
  undefined symbols are not all listed for that file fails the build,
  so the raw allocator, the slab caches, `Ram_quota`'s byte charge,
  `L4_timeout`, `Utcb`-reading internals and every deleted path are
  forbidden by not being listed, and `entry.cpp`'s one line is the
  common return path: its other calls are the cores'.
* **`fiasco/erx_boot_allocators.txt`**: the boot-time functions that
  may call the raw page allocator before the root budget exists, each
  in an initialization section. With the funnel, these are the only
  call sites of the raw entries the linked kernel may hold.
* **`tools/check_vectors.rb`**: the vector-route check of B1, over the
  vector table and the three stubs.
* **`abi/` additions**: `erx_boot_handoff` with `pool_usable`,
  `pool_heap` and `pool_regions`; `boot_kernel_path`; the
  `erx_create_kind` enumeration with its default-rights table; typed
  declarations of the root slots; the kernel profile of `erx_elf_plan`
  with its two views; the `charge`, `size` (`hlock`, `kip_size`,
  `koptions_size`) and pool declarations of `abi/backend/fiasco.txt`;
  the crash frame's constants, which the kernel design declares; in
  `abi/arch/aarch64.txt`, the user mask of `state`, `fp_control` and
  `fp_status` and the fixed value of `state`, from which the generator
  emits `erx_regs_admit`; and in `abi/manifest.txt`, a `memory_min
  u64` field of `erx_manifest`, the smallest RAM the platform admits,
  which the packer writes from the platform table and the kernel checks
  against the device tree. The manifest's `platform` field stays the
  platform's name; the record it names is the packer's, and
  `memory_min` is the one figure of it the kernel needs. The grammar
  changes the calls need (register words and UTCB aggregates, the
  `executor` attribute on waiting calls) are
  [design-abi.md](design-abi.md)'s.
* **The fork's configuration**: `config/fiasco/kernel.defconfig` keeps
  `CONFIG_PERF_CNT_USER` set, so user mode reads the performance
  counters directly (`useren`, `arm/perf_cnt-arm.cpp`) for profiling.
  They count kernel and user execution alike
  (`arm/64/perf_cnt-arm-64.cpp`), so a domain can observe CPU-wide
  activity without a trap, against the kernel's security contract
  ([Security](design-kernel.md#security)); this is a difference that
  remains, acceptable only because development builds run trusted code,
  and the benchmarks still time themselves by the time page's counter.
  `Irq_shortcut` is zero. The configuration the build checks is the
  resolved one, `globalconfig.out`, which Fiasco's Kconfig writes from
  the defconfig after every `select` and `depends on` has been applied
  (the `fiasco-kernel-config` step of `tools/lib/erx/fiasco.rb`), not
  the defconfig itself, since a `select` can set what the defconfig
  leaves unset. `tools/check_fiasco_config.rb` reads that file and
  requires `CONFIG_FPU=y`, `CONFIG_PERFORMANCE=y` and
  `CONFIG_PERF_CNT_USER=y`, and `CONFIG_LAZY_FPU`, `CONFIG_ARM_SVE` and
  `CONFIG_CPU_VIRT` absent or `is not set`; the fork's `Kconfig` has no
  `LAZY_FPU` option at all (**FP and SIMD state**), so that line of the
  check holds by construction and guards against the option being
  reintroduced. `CONFIG_CPU_VIRT` is pinned because the thread region's
  range is a constant of the non-hypervisor layout (**Thread blocks**).
* **Build**: erXos's LLVM build compiles the cores for the target with
  `-ffreestanding -mgeneral-regs-only -mno-outline-atomics
  -fstack-usage -ffunction-sections` into one archive, checks the
  archive's undefined symbols against an allowlist (the `erx_effect_*` functions and
  Fiasco's `memcpy` and `memset`), and `tools/erx build fiasco` passes
  it to the inherited make as `ERX_CORE_ARCHIVE=`, which the fork's
  `Makeconf` adds to the kernel link; the glue alone has
  `include/erx/core/` on its include path. The glue is compiled with
  GCC's `-fstack-usage` as well. `-ffunction-sections` is what the
  stack proof's call-graph extraction requires of every object it reads
  ([design-arch-aarch64.md](design-arch-aarch64.md#stack-proof)): the
  extractor counts a `bl` as a call only with an `R_AARCH64_CALL26`
  relocation naming its target, and the assembler resolves a call to a
  `static` function in the same section without one, so with every
  function in its own section every call crosses a section and keeps
  its relocation; a function placed in a shared section by a
  `section(...)` attribute loses that and its callers are refused like
  any call without a relocation.
* **The glue's checks.** The glue is erXos's code, so the chokepoint
  rules bind it, each with a seeded violation that fails the build:
  lookup (B2: no capability-valued parameter and no lookup reference),
  allocation (B9: no raw allocator or slab reference in the glue, and
  over the linked kernel, since inherited callees allocate below the
  glue, every call site of the `noinline` raw entries is the funnel's
  backing, the reaper's free step through `erx_page_free`, the sink, or
  a function of `fiasco/erx_boot_allocators.txt`, each in an
  initialization section; the slab layer is not built, so a slab
  reference anywhere fails the link), registers (B11: no `erx_regs_t`
  or `erx_uframe_t` parameter in the glue, and the frame's state word
  written only in `Erx::regs_load`), requests (`Context::enqueue_drq`
  private with `Context::drq` and `Erx::request` as its only friends,
  `Drq::No_wait` deleted from `Context::drq`, and `Erx::request`'s one
  `erx_object_ref` before its queue, checked in the syntax tree),
  shared access
  (B3: UTCB and kernel-user fields only through the generated
  accessors; no `Utcb *` or `Syscall_frame *` parameter but
  `erx_syscall`'s), the return path (the common return path calls
  `erx_return_check` before it restores registers, which the scheduling
  binding places), the console (the UART's register accessors referenced
  only from Fiasco's early-console driver, which the boot path,
  `erx_panic` and `erx_machine_end_effect` alone reach through the
  console effect), generated registers (no system-register instruction
  in the glue's disassembly outside generated accessors) and the
  forbidden interfaces (the import allowlist). Relocation and
  disassembly checks read the glue's GCC objects; the signature and
  field checks read clang's syntax trees of the preprocessed glue, which
  Fiasco's preprocessor emits as standard C++. The stack proof and the
  `musttail` rule do not bind the glue: its depth is measured, not
  proven (below).
* **The stack proof** runs over the cores' objects before the link,
  where their relocations are intact: its entries are the exported
  functions the image references, with `erx_effect_*` calls as leaves
  of the cost declared in `kernel/stack_fiasco.txt`, and its allowance
  is that file's share of Fiasco's thread block, one for call entries
  and one for the tick hook's. The report says `C17 cores: N bytes of
  the A-byte allowance; Fiasco's stack: unproven`. The boundary the
  proof assumes, that the cores run on a thread block whose remainder
  Fiasco and the glue use and that interrupts never nest inside the
  cores since the fork masks them in the kernel but at preemption
  points, is checked by measurement: the conformance suite reads
  Fiasco's stack fill watermark of every thread at the end of each run
  and fails when any thread's depth exceeds the block less the
  allowance, so an effect whose declared cost is too low shows up as a
  failed run, not a silent overrun.
* **The harness**: the transcript plan's `ends:` field and the report's
  `guest_end`; the crash-frame reader in `tools/lib/erx/crash_frame.rb`;
  `tools/erx bench null|ipc|park|timer|boot|stop`.

## Compatibility and migration

Replacing the stopgap moves nothing above the kernel: the cores, the
generated dispatch and `liberx` are the same files. The glue, the import
allowlist, the vector check, the charge and pool model of the `fiasco`
backend and the handoff record are deleted with the fork; erXos's kernel
has its own backend file under `abi/backend/`, and the packer admits
against whichever backend the image is built for.

## Failure handling, diagnostics and debuggability

| Failure | Where | What happens |
| --- | --- | --- |
| the image fails the validator | `bootstrap` | stops with `erXos image: <entry>: <reason>` on the console; nothing from the image is copied |
| the kernel entry is missing or not a `file` | `bootstrap` | stops, naming the path |
| the kernel's placement plan fails: a malformed header, a segment outside its entry, a placed range outside RAM or over the archive, the device tree, `bootstrap` or another segment; a metadata view missing, duplicated, too small, outside a segment or at another offset; the archive's rounded extent meeting the kernel's | `bootstrap` | stops with the planner's reason; nothing is copied |
| the pool plan fails: the heap it can select is below the model's floor | `bootstrap` | stops, naming the figure; Fiasco's own panic on an unfillable request is unreachable |
| the copied information page does not start with Fiasco's magic | `bootstrap` | stops, naming the view |
| a register record names a bit outside the user mask | `erx_thread_create`, `erx_thread_write`, `erx_vcpu_resume` | `ERX_EINVAL`; nothing stored |
| an object is destroyed while a request naming it is queued at another CPU | the destroy | the teardown runs; the record stays until the handler returns and drops the request's reference; the handler finds the object closed and withdraws |
| the handoff record's version is wrong, no descriptor covers the archive, or RAM is below `memory_min` | the kernel's start | `erx_panic`, cause `PANIC`, naming the check |
| the kernel's pool plan differs from the handoff's | the kernel's start | `erx_panic`, cause `PANIC`, naming both figures |
| the pool's free capacity is below the model's bound | the root task's start | `erx_panic`, cause `PANIC`, naming both figures |
| the applied charges differ from the plan | the root task's start | `erx_panic`, cause `PANIC`, naming the step |
| a thread of the root space faults, halts or the deadline passes | any CPU | `erx_panic` with the cause, the record, the frame, the end |
| a fault in a space whose fault gate is gone | the fault path | the thread stays stopped; the record is dropped and counted; the machine runs on |
| a foreign trap, a breakpoint, an undefined instruction in a domain | the trap | a fault record to the space's fault gate; the thread stops |
| a call names a stale or wrong capability | `erx_cap_lookup` | `ERX_ESTALE`, `ERX_ETYPE` or `ERX_ERIGHTS`, nothing changed |
| two destroys of one object | the close | the second finds the existence lock invalid and returns `ERX_ESTALE`; one teardown runs |
| a charge the budget cannot cover | the funnel | the call fails with `ERX_ENOMEM`; no page is taken |

A kernel assertion in inherited code reaches `erx_panic` first, so every
end leaves a crash record; the debugger, built into development builds,
is entered afterwards from the console's escape sequence.

## Security

Development builds run trusted code only, and the stopgap is never
hardened. Still, the properties that erXos's kernel holds by
construction hold in the fork by the same construction, because the code
is the same: one route from user mode and one lookup with generations,
rights that only shrink, one slot clear, one close winner, budgets as
space banks that own whole pages, W^X in the insertion path, no kernel
access through a user address, no decision on a user-writable value read
twice, no register record from user memory in a frame but through the
generated admit, no queue holding a pointer its request does not hold
counted, and no path from user mode to any protocol but erXos's. A
charge is admitted or refused at its own wall and waits for no one,
since it ends at the release, so what one domain is refused says
nothing about what another freed or when; what the budgets do not wall
off is the one physical free pool, Fiasco's buddy allocator on the
fork, and the backing of a charge that finds it empty takes released
pages off the list itself, whoever released them, and waits out their
grace period, fewer than two periods per part of 64 pages, only while
the machine has no free page, the bound the kernel design states; a
fault takes from its own pool and never waits
([Security](design-kernel.md#security)). User-mode
access to the performance counters stays enabled on the stopgap for
profiling, a side channel between domains that the boot audit lists
(K15) and **Differences that remain** records. What remains weaker is listed in the
scope table's **Differences that remain**: DMA is unconfined,
asynchronous errors are counted and not contained, Fiasco's own stack is
measured and not proven, and `sigma0`'s task holds an identity mapping
of device memory that nothing can ask it to map. The harness never
renders guest output on the host terminal; the crash frame is base64,
and the report's prose is escaped.

## Verification and testing

Each check comes with a seeded failure that proves the code under test
ran.

| Check | Passing case | Seeded failure |
| --- | --- | --- |
| the vector route (B1) | every user-mode vector entry is one direct branch to one of the three stubs, each stub's body holds the prologue, its one named first call and no indirect branch, and `erx_user_sync_entry` calls `erx_fault_classify` first | a vector entry pointed at a revived `arm_esr_entry` fails; an asynchronous-error entry restored to Fiasco's `ENTRY` template fails; an inlined decode of the syndrome ahead of the classify call fails; a `blr` seeded into a stub fails; a revived `do_syscall` called from `entry.cpp` after the classification fails the per-file allowlist |
| every exception class | the hostile suite raises a foreign trap, a breakpoint, an undefined instruction, an SVE instruction, an alignment fault and both memory-fault kinds on every CPU and sees each as its fault record or populate; an FP instruction in a fresh thread runs without a trap, and FP values survive a switch between two threads of different spaces on one CPU and a migration between CPUs | a class routed to Fiasco's slow trap ends with a kernel panic and fails; a build with `CONFIG_LAZY_FPU` set fails the configuration check, and, run anyway, turns the first FP instruction into a fault record and fails the FP case |
| the fork's configuration | `tools/check_fiasco_config.rb` over the resolved `globalconfig.out` of every kernel build finds `CONFIG_FPU`, `CONFIG_PERFORMANCE`, `CONFIG_PERF_CNT_USER` and `CONFIG_SYNC_CLOCK` set and `CONFIG_LAZY_FPU`, `CONFIG_ARM_SVE` and `CONFIG_CPU_VIRT` unset, `CONFIG_SYNC_CLOCK` because the finishing share is measured by `Timer::system_clock()`, which reads the counter only with it ([design-stopgap-scheduling.md](design-stopgap-scheduling.md#stop-and-exit)); a host test runs the check over a resolved file with each required line present and each forbidden one absent | a resolved file with `CONFIG_LAZY_FPU=y`, the case a `select` would produce, fails the check; a resolved file with `CONFIG_CPU_VIRT=y` fails it; one with `CONFIG_SYNC_CLOCK` unset fails it; a `LAZY_FPU` option seeded back into the fork's `Kconfig` with its `select` restored makes the real build's resolved file fail the same way |
| the import allowlist | the glue's undefined symbols are all listed for their files | a glue call of `Kmem_alloc::q_alloc`, of `L4_timeout::microsecs_abs` or of a deleted path fails the build; a Fiasco internal called from `entry.cpp` fails |
| inherited allocation (B9) | the linked kernel's call sites of the raw page allocator are the funnel and the listed boot-time functions; no slab symbol is defined | a revived `Fpu_alloc::alloc_state` fails the link; an inherited runtime function given a direct `Kmem_alloc::alloc` fails the call-site check; a listed function moved out of its initialization section fails |
| the glue's signatures and fields | no glue function takes a capability value, a `Utcb *`, a `Syscall_frame *`, an `erx_regs_t` or an `erx_uframe_t` but `erx_syscall`'s frame, no glue source names a header field or a UTCB field, and the frame's state word is written only in `Erx::regs_load` | a seeded parameter, a seeded field access and a seeded state-word write each fail |
| registers from user memory (B11) | `erx_thread_create`, `erx_thread_write` and, from M5, `erx_vcpu_resume` with a privileged mode, a masked interrupt or a reserved FP control bit return `ERX_EINVAL` and change nothing; a thread started with the flag bits set sees them and runs in user mode with interrupts enabled; `erx_thread_read` of a stopped thread reports only user bits, and writing them back succeeds | the generator's test seeds a user mask that admits the mode bits and fails; a loader seeded to skip the fixed value fails the mode case |
| queued requests (B10) | an IRQ object delivering to a thread on another CPU is destroyed while its delivery is queued, ten thousand times on QEMU with four CPUs and on the hosted kernel under ASan: every run ends with the object freed once and the thread either delivered to or not, never faulted | the request's reference seeded away lets the handler touch freed memory, which ASan reports |
| the UTCB layout | the glue's `static_assert`s pass | a field inserted into the generated layout fails the build |
| a deadline read once (B3) | a thread that rewrites the deadline word of another thread's call after that call entered changes nothing about when the wait ends | the glue passing a `Utcb *` to a re-reading internal lets the rewrite take effect and fails |
| opaque cores and the opaque header | no file outside `kernel/core/` includes an `_impl.h` or defines `ERX_CORE_INTERNAL` | a glue file that includes one or defines it fails |
| the charge model | every constant's `static_assert` holds | a model constant changed by one fails |
| the plan at boot | the conformance boot starts the root task | a seeded extra allocation in the glue refuses the start with the named step |
| the pool plan | the boot under TCG and HVF with 1 and 4 CPUs, at 512 MiB and at the platform's `memory_min`, passes the kernel's comparison of `heap` and `regions` and prints both figures; host tests feed the plan a map with a reservation straddling a unit boundary and find the loss counted, a map whose free memory exceeds the window and find `heap` cut to the window with `usable` untouched, a map of more ranges than the region limit and find the plan refused with the count, the same map with two ranges merged and find it admitted, and a map with a hole where Fiasco's top-down walk would cut and find the same ranges; the monotonicity test grows RAM, shrinks each reservation, and adds small ranges above a large one within the limit, and finds `heap` never smaller | a plan that subtracts byte sizes without rounding predicts more than Fiasco holds and is refused at boot; a plan that lets the limit choose a top-down prefix instead of refusing predicts a smaller `heap` after small ranges are added above a large one, which the monotonicity test catches; a plan that passes `usable` as `kmemsize` on the window-bound map makes Fiasco panic on the unfillable request, which the boot test reports; `boot_reserve` set below Fiasco's real use refuses the start |
| the pool bound | the root budget's guarantee is at least `heap - boot_reserve(cpus, heap)` under both accelerators with 1 and 4 CPUs, at 512 MiB and at `memory_min` | as above; the per-heap-page term set below the page records' and the thread region's tables' real size refuses the start |
| the rounded alias | a boot whose archive follows the kernel by a whole unit maps the alias | a recipe placing the archive in the kernel's last unit stops in `bootstrap` with the placement reason, and with that check removed panics in `add_pmem`, which the test reports as the regression |
| the archive's alias | the root planner reads the manifest and `erx_image_map` copies the writable segments | the alias removed makes the kernel's read fault and the boot fails before the root task |
| `memory_min` | a boot at `memory_min` starts; a boot below it refuses, naming both figures | the check removed lets the smaller boot start and fail at the pool bound instead |
| the placement plan (B6) | each validator fixture stops in `bootstrap` with its reason; a kernel whose segments the plan places boots; the planner's kernel profile and `erx_boot_place` are fuzzed with ASan on the host | a boot with the validator call removed starts the kernel and fails the test; a fixture whose segment would land on the archive is placed by a plan with the overlap check removed and fails the fuzz run |
| the metadata views | the fork's kernel, whose views lie inside loadable segments, plans; the host test accepts a view at the end of its segment and refuses a second view of a type, a view one byte short of `kip_size` or `koptions_size`, a view straddling two segments, and a view whose file offset does not match its segment's | a reader that treats the views as placements refuses the fork's own kernel for overlap; a reader without the containment check accepts the straddling fixture, and `bootstrap`'s descriptor write lands outside the copied bytes, which the fuzz run's bounds check catches |
| the archive preserved | the manifest read at boot equals the packed one, byte for byte, after the kernel was placed | a kernel fixture whose segment overlaps the archive, with the plan's reservation order reversed, corrupts the manifest and fails |
| the first entry | the root task's first instruction sees the boot information page's address in its argument register and zeros in every other register the plan did not set; a created thread sees the registers its creator wrote | a `user_invoke` that loads Fiasco's information-page word into a register fails the register test |
| the root space's fault (K31) | a partial boot whose program faults the root thread ends with cause `FAULT` | the fault path routed to kill the thread ends with `WATCHDOG` and fails |
| a gate-less ordinary space | a parent destroys its child's fault gate and provokes a fault in the child: the thread is stopped, the space's inspection counts one dropped record, the machine runs on | the rule keyed on the absence of a gate ends the machine and fails |
| one close winner (B10) | two threads call `erx_object_destroy` on one object at once, on the hosted kernel under ASan and on QEMU with four CPUs: one succeeds, one gets `ERX_ESTALE`, the object is freed once | `invalidate` returning no old value lets both proceed and ASan reports the double free |
| attachment teardown | a thread deleted while bound gates have queued senders wakes each sender with `ERX_EDEAD`, and the gates outlive the thread with no bound thread | a teardown that skips `att_gates` leaves a dangling pointer, which ASan reports in the hosted run |
| space teardown | a space with mappings of several objects is destroyed; every object's reverse map is empty, every translation table but the root directory is on the released list, the root directory holds no valid entry and stays held, and the space's budget's `used` is down to its records and that one page before the destroy returns; a page of a destroyed mapping is not reused until the invalidation completed and its grace period ended, checked by the host test of `erx_tlb_plan` and the released list's stamps; the root directory is released at the record's free, and a finishing thread of the space, preempted on another CPU through the destroy, is switched to and dies with the directory still held, on QEMU with four CPUs | the mapping-database unmap retained in place of the space teardown leaves translations behind, which the hosted kernel's table check finds; a teardown seeded to release only at the put leaves `used` high until the grace period, which the counter check catches; a teardown seeded to release the root directory at the destroy lets the switch to the finishing thread load a released page, which the debug assertion in `make_current` that the page `_dir_phys` names is held catches, with released pages poisoned; `Mem_space`'s stock destructor body restored frees the lower tables a second time at the put, which the released list's host model and ASan report |
| the retire | a page released while no batch is in progress, and one released after one CPU has reported its quiescent state for the batch in progress, each stay on the list until a batch that began after the release has heard from every active CPU, on the hosted kernel's model of `Rcu_glbl`; a put retired while a batch is in progress matures fewer than two batches after its retirement | a release stamped `_current` lets the first page mature at once and the second while that CPU still holds its pointer, which the model's check catches; a put stamped at a later promotion rather than at its retirement, as Fiasco's `_n` list stamped its items, is a batch late, which the model's bound on maturity catches |
| every lock a ticket lock | the core's `erx_spinlock_t` on the host under ThreadSanitizer: eight threads take and release one lock in a loop for a minute, each counting the releases between its draw and its take, which never exceeds seven; the linked kernel's `Spin_lock<>::lock_arch` and `unlock_arch` call `erx_spinlock_lock` and `erx_spinlock_unlock`, by the disassembly check, and `Arch_lock` is absent from the multiprocessor interface; the conformance boot brings four CPUs up through the trampoline's ticket-drawing copy of the take; on the hosted kernel under TSan, three CPUs report quiescent states without pause while a fourth releases pages, and no release waits longer than `ncpus - 1` critical sections of the tracker's lock | the stock flag protocol restored in `lock_arch` lets a thread count more than seven releases passing it, which the host test reports, and lets the releasing CPU lose the tracker's lock without bound, which the hosted timing check catches; the trampoline's copy left at the flag protocol takes the lock by its flag bit while the C++ side releases by its serving half, so the second application CPU waits forever and the four-CPU boot fails the harness's CPU count |
| a thread's construction (B9) | a budget destroyed while a thread of it is being created, at each step of the creation on the hosted kernel: the creation returns `ERX_ESTALE`, the block's two pages and the kernel-user page are released and refunded at the dead budget, the slot is returned and the budget's tombstone is freed; the same for a memory object and a task | a creation seeded to take the thread's existence lock before its block exists reads unmapped memory, which the hosted kernel's ASan reports; one seeded to join the task's thread list before its backing leaves a teardown that finds `charged` above `backed`, which the debug assertion catches |
| the record step | a thousand gates destroyed and a thousand threads killed on one CPU are served at 64 items a step, the gates' puts and the threads' wakes in one order, each tick's handler running one bounded step, and the idle thread drains the rest in steps when the CPU idles; `Rcu::call`, `Rcu_data::do_batch` and the `_n`, `_c` and `_d` lists are absent from the image | the step's limit removed runs the thousand in one tick handler, which the timing test's bound on a stretch with interrupts masked catches; a dying thread's wait queued on a list of its own, promoted and run as Fiasco's `_d` was, fails the image check and, run anyway, matures a batch late and wakes the thousand in one pass, which the same bound catches; `enter_tickless_idle` entered with a non-empty stamped list leaves them unreaped, which the test catches |
| the page records | the boot carves the record array from the top of the highest heap region before the buddy allocator receives the heap, at 512 MiB and at `memory_min`, and every page of the span has a record | the array taken from the raw entry fails the allocator's 1 MiB maximum at 512 MiB, which the boot test reports |
| the table adapter | `Mem_space::v_insert` at a fault builds a table from the space's pool through `Erx_table_alloc`, with the raw entry's take counter unchanged | `Kmem_alloc::q_allocator` restored fails the call-site check; a `v_insert` seeded to take from the raw entry fails it too |
| one owner per page (B9) | the accounting check, held plus released plus free equal to the root budget's guarantee, holds at the end of the conformance and hostile runs and again after the idle threads have drained the released list; the exhaustion tests through every object type succeed and release | a seeded uncharged page taken by the glue fails the accounting check; a seeded release that refunds before it appends fails the chokepoint check |
| the funnel on a full machine | on QEMU with four CPUs, one domain releases and commits its whole guarantee without pause on three CPUs while another creates objects, commits and touches fresh ranges on the fourth, with no idle CPU: every creation and every commit succeeds, no part of a backing waiting longer than two grace periods, and every touch succeeds without a call of the raw entry; the same on the hosted kernel under TSan | the backing seeded to take nothing off the released list turns the raw entry's empty answer into a wait past the bound, which the test catches; a fault path seeded to call the raw entry fails the call-site check |
| thread blocks under fragmentation | a domain commits a run of pages as large as its guarantee allows, releases every other page, waits a grace period, and creates threads until its budget is spent: every creation succeeds, while the hosted kernel's allocator check finds no order-1 block free throughout | thread blocks seeded to come from the window as order-1 blocks make a creation fail with `ERX_ENOMEM`, which the test catches |
| a record's cache page through the grace period | a domain at its cap destroys a thousand gates and creates a thousand at once: refused with `ERX_ENOMEM` while the destroyed records wait and admitted once their grace period and the ticks their backlog needs, one per 64 records queued on a CPU, have passed, the kernel design's case run on the fork | a cache page seeded to be released at the destroy lets a parked call read a freed record on the hosted kernel, which ASan reports |
| the kernel-user page's owner | a thread deleted while its space lives releases its page; a space deleted with its threads releases every thread's page once | a page released by both teardowns is appended twice, which the released list's host model and ASan report |
| the rendezvous without items | a message with items is refused `ERX_EINVAL` | the refusal removed passes items and fails |
| executors and reply | `erx_ipc_reply` from an executor returns `ERX_ENOCALLER`; every waiting IPC call returns `ERX_EWOULDBLOCK` | a call declared without its attribute fails the generator |
| the IRQ shortcut off | a thread woken from `erx_ipc_wait` by an IRQ object returns with the status the binding translates, and a stop pending at that wake takes effect at the return | `Irq_shortcut` set makes the wake skip the translation; the returned status is Fiasco's and the test fails |
| the performance counters | the boot audit reports user-mode counter access as enabled, and a domain's read of a counter register succeeds, as the stopgap's difference states | a build that leaves the audit line out fails |
| the crash frame (B7) | the four causes in both forms decode and validate from the serial log | a frame cut one line short reports `truncated`; a flipped payload byte, a brief frame carrying a full record's length and a full frame whose record says brief each report `corrupt`; all fuzzed |
| the guest's end | each K31 case reports `guest_end: self` | a kernel whose end line is removed reports `failed` |
| the pet-stop hook | the hook build ends at the deadline with cause `WATCHDOG` | an ordinary build with the key runs on |
| console ownership | the host test of `erx_console_owner_step` moves the owner only on the console entry's carve; a partial boot's `erx_debug_log` lines appear after root start for the whole run | a step that ignores the entry's identity moves the owner on any carve and fails the host test |
| the stack watermark | every thread's measured depth stays within the block less the cores' allowance | an effect declared cheaper than it is, with a workload that drives it, exceeds the bound and fails |
| the stack proof's scope | the report names the C17 scope | a report line naming the kernel stack fails |

The conformance suite, run under TCG and HVF on one and four CPUs,
drives every call and status the stopgap carries; the hostile demo runs
two native domains with threads on every online CPU for ten minutes in
each of those four configurations. The stop, park and urgency cases are
the scheduling binding's.

## Performance

The trap path adds, over Fiasco's native call, the register snapshot
and the generated decode with one lookup under a sequence count, an
estimated 10 ns under HVF against Fiasco's measured 29 ns; the
benchmarks of gate G1 measure it. Neither the header in `Kobject` nor
the 64-byte slot changes any fast path's crossings. Turning the IRQ
shortcut off adds a switch and a return through the waiting call's
frames to each wake by an IRQ object, an estimated few hundred
nanoseconds under HVF, which the `park` and `timer` benchmarks measure.
Eager FP switching saves and restores 528 bytes at every switch
between threads, whether or not they use FP, where lazy switching
would have cost a trap on first use and nothing for threads that never
touch it; the `ipc` benchmark's cross-space row carries that cost, as
erXos's kernel does. Per-budget caches cost each budget at most one
partly used page per record kind. The crash frame writes at most about
22 KiB of base64 at a panic, bounded by `ERX_CRASH_SIZE`.

## Portability

The stopgap runs on QEMU `virt` only, under TCG and HVF, with the
kernel's physical-memory window of 1 GiB as its memory limit. The boards
come with erXos's kernel.

## Dependencies

None beyond the imported Fiasco set
([design.md](design.md#dependencies)).

## Alternatives considered

* **Emulating the interface above Fiasco**, in `liberx`, over Fiasco's
  native protocols. Rejected by the owner: a test would then test the
  emulation, and enforcement would depend on callers using `liberx`.
* **A list of absent symbols** as the proof that no protocol is
  reachable. Rejected: native invocation is a virtual interface, native
  lookup is inline and exception dispatch has more than one vector, so a
  renamed, inlined or re-routed path survives a symbol list, and each
  discovery would add a name. Deleting the interfaces from the source
  and checking the vector table proves the route by construction.
* **Admitting Fiasco's own trap immediate from the `sigma0` task alone**,
  so that `sigma0`'s thread can run its wait loop. It keeps
  `sys_ipc_wrapper` and every `invoke` protocol in the image for one
  task's sake; nothing sends to `sigma0`, so the thread would only wait.
  Not starting the thread, and not shipping its executable, deletes the
  mechanism instead.
* **Carrying the kernel as an `image` entry** with a packer-written
  manifest, so that `bootstrap` reads no ELF at all. Fiasco's kernel has
  nine loadable segments, more than the manifest's eight, and two
  custom program-header types the manifest cannot express; a kernel
  profile of the one reader costs less than reshaping the kernel's
  link.
* **A `sigma0` pager for the root task**, with a refused fault reported
  through a new path. Unneeded: Fiasco runs a task without a pager, the
  plan maps the image whole, and the fault decision routes a root fault
  to `erx_panic`.
* **Keeping the IRQ shortcut and checking for a pending stop** before
  taking it. Rejected: the shortcut skips the binding's completion for
  every wake, not only a stopped thread's, so the check would have to
  reproduce the completion in assembly.
* **Fiasco's slab caches with a page-level charge added.** Rejected: the
  caches are global per type, so a page would still hold records of
  several budgets, and no budget could own it.
* **A separate `erx_null` call** for the benchmark. A call added for
  measurement is interface the kernel does not need;
  `erx_thread_set_urgency` with an unchanged value is the same work.
* **An outer checksum on the crash frame** over the base64 payload.
  Unneeded: the record's own CRC covers everything after its length and
  CRC fields, and the reader checks the fields before it by value.
* **Hex rather than base64** for the crash frame: half the density for
  the same bound; base64 keeps the frame under 300 lines.
* **Proving the stack over the linked image** with GNU ld's
  `--emit-relocs`. The cores' objects carry their relocations before the
  link, and the glue's effects are leaves of declared cost either way;
  proving before the link avoids depending on what GNU ld keeps.
* **Keeping lazy FP switching with a first-use case in
  `erx_fault_classify`.** Rejected: it would make a classification
  result that allocates, in a trap the kernel design treats as a fault
  record, for a saving erXos's kernel does not take either; eager
  switching has no trap and no allocation.
* **FP state in the kernel-user page** instead of the thread block.
  Rejected: the page is user-writable, so the kernel would restore
  registers from memory the thread rewrites, and the page is already
  laid out by the ABI file.
* **Thread blocks as order-1 blocks of the window**, Fiasco's own
  allocation. Rejected: an accounting in pages admits a charge the
  buddy allocator cannot serve once the free pages have no free
  buddies, so a creation would fail on another domain's fragmentation
  with no released page to wait for, a cross-wall denial the budgets
  are meant to exclude; the thread region makes every allocation order
  zero and the failure unrepresentable.
* **4 KiB thread blocks** (`CONFIG_CONTEXT_4K`, which `src/Kconfig`
  marks experimental on 64-bit targets). Rejected: the block holds the
  record, the FP state and the kernel stack, Fiasco's stack is measured
  and not proven, and an overflow would run into the record with no
  guard; the thread region keeps the 8 KiB Fiasco was sized for.
* **A pre-split store of thread blocks** taken at boot. Rejected: such
  a store is a second pool with a capacity of its own, so a creation
  whose charge was admitted could still find the store empty while
  pages are free, the same failure at another limit.
* **Chaining the released list through the released pages** instead of
  page records. Rejected: a released page may still be read by a call
  that found it before a preemption point, which is what its grace
  period protects, and a link written into it is a write to memory
  under that protection.
* **Draining every request queue at a destroy** instead of counting a
  queued request as a reference. Rejected: a drain must know every
  queue a pointer can sit in, which is the open-ended list the
  reference rule removes.
* **Checking Fiasco's `ENTRY` template** for the asynchronous-error
  entries instead of a direct stub. Rejected: the template's target
  lives in a register across a shared body, so the check would have
  to follow a register value; a direct stub makes the target a symbol.
* **Masking a register record silently** instead of refusing it.
  Rejected: a record with a privileged bit is a bug or an attack, and
  a read-write round trip succeeds either way since the read shows
  only user bits.
* **Treating the kernel's metadata headers as placements.** Rejected:
  they overlap their loadable segments by construction of Fiasco's link
  script, so the overlap check would refuse every kernel.

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| the pool plan's reproduction of Fiasco's free-map rounding drifts from `kmem_alloc.cpp` | low | a refused boot | the kernel compares the plan with the handoff at every boot, under both accelerators with 1 and 4 CPUs, and the host test pins the rounding cases |
| Fiasco's boot reserve varies with CPU count or configuration beyond the model's bound | medium | a refused start | the bound is checked under both accelerators with 1 and 4 CPUs, and the kernel prints both figures |
| clang cannot parse the preprocessed glue for the syntax-tree checks | medium | the signature, field and request checks have no reader | the glue is erXos's code, so it is kept within the standard C++ Fiasco's preprocessor emits and the build fails until clang parses it; the import allowlist and the disassembly checks hold regardless, but a symbol-table check sees neither parameter types nor field writes and is no substitute |
| Fiasco's eager FP implementation has seen less use than its lazy one | low | a switch that loses FP state | the FP cases of the conformance suite under both accelerators, and the hostile demo's threads, which use FP on every CPU |
| mixed GCC and clang objects disagree on an ABI detail | low | a link or runtime failure | the archive's undefined symbols are allowlisted, both use AAPCS64, and the conformance boot is the test |
| the kernel's 1 GiB physical-memory window | certain | memory beyond it is unusable on the stopgap | QEMU guests at 512 MiB; a limitation, not a defect |
| the window's region limit of 8 | low | a fragmented memory map is refused | the plan counts the free map's ranges and refuses, on the host over the platform's table before placement and at boot over the actual map with a diagnostic naming the count; QEMU `virt` has one RAM range and no `/reserved-memory`, so its four reservations (the kernel image, the archive, `bootstrap`, the device tree) split it into at most five ranges; a platform that needs more raises `Mem_layout::Max_pmem_regions` and `pool_regions_max` together, which is one array's size |
| an inherited use of a thread block's physical address (`Kmem::virt_to_phys` on a context or its stack), which the thread region does not have | low | a wrong physical address for a block in a slot | no thread or context code of Fiasco's needs one once the kernel-user page is out of `Task::alloc_ku_mem`; Fiasco's converter has no assertion to catch one, `Mem_layout::pmem_to_phys` answers `~0UL` for an address outside every registered region (`arm/mem_layout-arm.cpp`), so the fork's call-site check lists every caller of `Mem_layout::pmem_to_phys`, `Mem_layout::phys_to_pmem` and `Kmem::kdir->virt_to_phys` in the linked kernel (`Mem_space`'s directory address and the page allocator's own use) and fails the build on a new site, with a seeded call in a context path proving it; the conformance suite runs every call on threads in slots |
| `boot_reserve`'s per-heap-page term, the page records and the thread region's tables, drifts from what boot takes | low | a refused start | the term is a formula of the heap, checked by the pool-bound test at 512 MiB and at `memory_min`, with the kernel printing both figures |
| an inherited reader of a `Spin_lock`'s word outside `spin_lock.cpp`, written for the flag bit (**Locks**) | low | a lock misread as free or held | `Arch_lock` is deleted from the multiprocessor interface, so such a reader fails to compile; the one assembly copy, the boot trampoline's, draws a ticket and is exercised by every four-CPU boot |

The thread region's range (**Thread blocks**), the previous crash
record's rights (the memory table of
[Rights](design-kernel.md#rights): as the machine page, plus `DESTROY`),
the absence of a `sigma0` executable (**`sigma0` and the mapping
database**) and `memory_min`'s place as a field of `erx_manifest`
([Interfaces](#interfaces)) are decisions, stated where they apply.

Open questions, each with a recommendation:

* **The raw allocator's call-site check.** It reads the linked kernel's
  disassembly, which inlining could defeat; the fork marks the raw
  entries `noinline`. Recommended: keep the check, and have it also
  require the entries to exist as symbols, so a build that inlines them
  away fails rather than passing empty.

## References

* [design-kernel.md](design-kernel.md): the interface and the scope table.
* [design-stopgap-scheduling.md](design-stopgap-scheduling.md): stops, park and wake, urgency and charging on the fork.
* [design-scheduler.md](design-scheduler.md): groups, park and wake, service work.
* [design-system.md](design-system.md): the root task's bootstrap and partial boots.
* [design-programs.md](design-programs.md): `erx_elf_plan`.
* [design-abi.md](design-abi.md): the checker and the ABI grammar.
* [design-build.md](design-build.md): the frozen stopgap build.
* [design-arch-aarch64.md](design-arch-aarch64.md): the system-call trap, the vector table and the stack proof's instructions.
* [design-platforms.md](design-platforms.md): QEMU `virt`, the crash record, ending the machine.
* [plan.md](plan.md): milestone M1 and gate G1.
* Fiasco sources under `fiasco/kernel/src/`: `kern/syscalls.cpp`, `kern/thread_object.cpp`, `kern/thread-ipc.cpp`, `kern/ipc_sender.cpp`, `kern/ipc_gate.cpp`, `kern/obj_space.cpp`, `kern/kobject.cpp`, `kern/kobject_iface.cpp`, `kern/ref_obj.cpp`, `kern/switch_lock.cpp`, `kern/ram_quota.cpp`, `kern/kmem_slab.cpp`, `kern/std_workload.cpp`, `kern/task.cpp`, `kern/map_util.cpp`, `kern/kmem_alloc.cpp`, `kern/buddy_alloc.cpp`, `kern/rcupdate.cpp`, `kern/context_base.cpp`, `kern/config_tcbsize.h`, `kern/kernel_thread.cpp`, `kern/app_cpu_thread.cpp`, `kern/koptions-def.h`, `kern/arm/thread-arm.cpp`, `kern/arm/config-arm.cpp`, `kern/arm/context-arm.cpp`, `kern/arm/kmem_alloc-arm.cpp`, `kern/arm/mem_layout-arm.cpp`, `kern/arm/mem_space-arm.cpp`, `kern/arm/perf_cnt-arm.cpp`, `kern/arm/64/ivt.S`, `kern/arm/64/thread-arm-64.cpp`, `kern/arm/64/entry_frame-arm.cpp`, `kern/arm/64/fpu-arm.cpp`, `kern/arm/64/mem_layout-arm-64.cpp`, `kern/arm/64/mem_unit-arm-64.cpp`, `kern/context.cpp`, `kern/irq.cpp`, `kern/fpu_alloc.cpp`, `kern/syscalls-log.cpp`, `jdb/arm/jdb_trace_set-arm.cpp`, `jdb/arm/64/jdb_trace_set-arm-64.cpp`, `abi/l4_types.cpp`, `lib/libk/slab_cache.cpp`, `kernel.arm.ld`, `Kconfig`; `fiasco/bootstrap/server/src/startup.cc`, `exec.cc`.
