# The Phase 1 backend

Phase 1's kernel is Fiasco, near stock, imported under `fiasco/`. `liberx/backend/fiasco`
implements erXos's calls on it, in user mode. This backend is the current implementation behind an
interface erXos owns: the generated C functions of
[design-runtime.md](design-runtime.md#the-liberx-interface), defined by
[design-kernel.md](design-kernel.md). At M7 the `erx` backend replaces it and nothing above
`liberx` moves.

Four constructions carry the document:

* **One owner, one thread.** The root task holds every Fiasco capability and every page, and one
  thread of it, the root service, alone touches the tables that record them. Every other thread,
  the root's included, sends it a request or a fault and waits. So the root's tables need no lock,
  a request cannot overlap its task's exit, and ending a task, a tree of tasks or a budget is a
  list one thread walks.
* **Handles flow down.** A handle reaches another task only by `erx_cap_pass` from the caller's
  own table into a space the caller created, and nothing passes at a rendezvous. So every holder
  of an object is its creator's task or a task below it, a task's sub-spaces end before it does,
  and what ends with a task has no holder left in a live task. So ending a task's objects with
  it and destroying an object or a budget are safe at any moment: every use of a handle goes
  through the service's one lookup, and every mapping is revoked with its object. Safe is not
  the same as timely: when to delete stays the caller's decision, and the domain library still
  deletes a connection's objects only once each party has unmapped them or ended
  ([design-domains.md](design-domains.md#connections)).
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

and, on the user-facing system:

> yeah let's front-load user facing stuff

**Phase 1** in this document includes Phase 1b of [plan.md](plan.md): the user-facing system
carried further on the same backend, behind the same interface, with every guarantee still
deferred. Its consumers are:

* the system domain: its release, the console, the host link, the device service, the domain
  library and the domain service;
* **domains** and their connections: the web domain, the session domain, the display domain,
  the network domain, the storage domain and test domains, each a task the domain library builds;
* **programs in sub-spaces**: toybox and recompiled programs, started by a session's port driver
  with their channels, pipe ends and code objects, and littlefs as the storage domain's
  sub-space port;
* **drivers in their own domains**: virtio-mmio block, net, gpu and input, each held by the
  domain the manifest names.

From them:

* **It promises**, for trusted workloads: the results in [the call table](#the-call-table), no
  memory errors, no deadlock, and exact accounting of whatever it reports.
* **It refuses** a call with no consumer in that list with `ERX_ENOTSUP`, which every caller
  checks.
* **It reports as unknown** what only a kernel could know: `unsupported`, or `partial` with its
  reporter and scope, never a made-up number.
* **It does not promise** what [What Phase 1 defers](#what-phase-1-defers) lists, with each known
  gap in one line: isolation between tasks, budgets and grants as limits, and every bound on a
  kernel path among them.
* **It contains** only mechanisms with a consumer in that list and stored fields with a reader, in
  L4Re's shapes wherever L4Re has one. It never rebuilds in user mode a property that only erXos's
  kernel promises.

[Read in source, never run](#read-in-source-never-run) lists what the first packages must check; a
claim that fails changes this document.

## Ownership and authority

Everything above `liberx` calls the generated functions. Each has one stub, in every image, the
root's included. The stub runs locally, for calls that never need the kernel, or sends a request to
the [root service](#the-root-service), which runs the call's body.

### Capabilities in Fiasco's object space

The root holds a capability to every object it creates, with Fiasco's delete right, so
`l4_task_delete_obj` always reaches it. Callers hold **handles**: indices in a per-task handle
table the service keeps, never Fiasco capability values. An entry names an object record of the
service's and the generation that record had when the entry was made; a record's generation, 32
bits, grows each time the record is freed, and a record whose generation would wrap is retired and
never reused, so a handle to an object that has gone answers `ERX_ESTALE` and never names its
successor, however often records are reused. The entry itself carries no generation: an entry a
close freed is reused, so a handle used after its own close names whatever its entry names then,
where erXos's kernel answers `ERX_ESTALE`, a recorded difference. A handle carries no rights: the
service answers the few rights it checks from the object's record, its creator and its kind, and
records no rights for a handle, since rights are a capability mechanism only erXos's kernel
enforces ([What Phase 1 defers](#what-phase-1-defers)). Thread handles are the exception
[Thread creation](#thread-creation) describes. Each task has a run of slots in the root, past the root's own: its
threads, its semaphores, its gate, its space and the semaphore its end ups. Another task holds only these, mapped by
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
| dispatcher | each task, one | turns IRQ deliveries into triggers of the task's groups | drivers, lanes, channels, pipes, ERTS's wakes |

A task's own threads create its reaper and its dispatcher, at backend initialisation, through the
ordinary calls; the dispatcher's creation registers it with the service. The root's dispatcher starts with the
root's first group instead, as that group's first thread ([Budgets and groups as records](#budgets-and-groups-as-records))
([Interrupts and readiness](#interrupts-and-readiness)). The watchdog, like the root service, holds no thread index and
takes a free slot of the kernel-given UTCB page, with `sigma0` as its pager. `moe`, L4Re's root task, is likewise one server thread for
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
| park lock | one per group | a group's epochs, parked list, ready list |
| trace lock | root | the trace ring's writes; its reader takes none ([The trace ring](#the-trace-ring)) |

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
   `sigma0` answers a page fault of the root with (`init_mem.cc:73`, `memmap.cc:170-176`):
   `Root_section_rwx` for the root's image, whose segments one range cannot tell apart, and
   `Root_section_ro` for the archive.
4. `erx_boot_handoff_write` writes the `erx_boot_handoff` record of `abi/kernel.txt` (flags, build
   identifier, index hash, the archive's range, `/chosen/bootargs` cut at the last whole word, and
   the full path of the node `/chosen/stdout-path` names: libfdt resolves the value up to its first
   `:`, a path or an alias of `/aliases`, and the path is empty when that names no node or is longer
   than `ERX_BOOT_STDOUT_PATH_MAX`; and the boot value with its slot, which `erx_boot_pair_derive`
   computes from `/chosen/bootloader`'s `partition` and `tryboot`
   ([design-platforms.md](design-platforms.md#data-model)), `unknown` with slot `none` when either is
   missing or malformed or the partition is not a slot)
   into the options block for the kernel. That block is mapped into no task, so it also writes the
   record, by `erx_image_load`, into the **handoff page**, a free page from
   `mem_manager->find_free_ram`, reserved as `Region::Root` with `Root_section_ro`; no free page
   refuses the boot, after the copy. The record's pool fields stay zero, with no reader.
5. `init_kip_infos` assigns the page's address to the kernel information page's `user_ptr`
   (`init_kip.cc:30`), which `boot_info_t` carries there.

**The kernel.** Its options are a constant, `Fiasco::KERNEL_OPTIONS` (`fiasco.rb`), built into
`bootstrap`, with neither `-serial_esc` nor `-serial_input`, and it is built without JDB. Its own
changes are `erx_handoff.cpp`: it accepts the record, refusing a boot value and slot that are not
one of the machine page's pairs, prints the banner (`development build: trusted code only`, the
build identifier, the index hash, then `erx: boot value <unknown|normal|trial> slot <none|a|b>`,
whose names come from a fixed table) and panics if no bootloader descriptor covers the archive. The fork's kernel-call route, `erx_probe` and `erx_syscall`, is out of its build
(`Modules.generic:112`), and its sources stay in `fiasco/kernel/src/erx/` for erXos's kernel to draw on. It
greets as erXos (`kip.cpp`). It starts `sigma0` and then the root (`std_workload.cpp`), with capabilities
at `L4_BASE_TASK_CAP`, `L4_BASE_FACTORY_CAP`, `L4_BASE_THREAD_CAP`, `L4_BASE_PAGER_CAP` (a gate to
`sigma0`), `L4_BASE_LOG_CAP`, `L4_BASE_ICU_CAP` (also the platform control object) and
`L4_BASE_SCHEDULER_CAP`; a stack pointer of 0; one page of UTCB slots (`std_workload.cpp:95`);
Fiasco's default priority, on the boot CPU.

**The root's first steps, in order.** Only the first thread exists until step 7, so it runs the
service's bodies directly.

1. Sets its stack, inside its image. Touching it faults to `sigma0`, which maps it one to one.
2. Maps the kernel information page with `l4sigma0_map_kip`, reads the handoff page at `user_ptr`
   through a page fault, and accepts the record with `erx_boot_handoff_accept`.
3. Maps its whole image at its physical addresses with `l4sigma0_map_mem`, and touches each page of
   the archive, so the fault path maps it read-only by its sub-type: `l4sigma0_map_mem` is `sigma0`'s
   RAM request, which maps read, write and execute whatever the sub-type says (`memmap.cc:125`). After
   this step no page of the root is mapped on demand.
4. Finds the archive's `system_manifest_path` entry, checks its file hash and reads it through the
   generated C reader, which allocates nothing and whose view stays in the archive, and reads the kernel
   command line from the handoff view's `bootargs` ([The command line](#the-command-line)). Later steps
   take device entries, wall offset, seed and the system's arguments from the first, and the watchdog's
   numbers and deterministic mode from the second.
5. Builds the pool window and contiguous pools ([The pool](#the-pool)). If the pool and the root's
   image together hold less than the manifest's `root_memory`, it refuses the boot.
6. Makes its own thread table ([Thread creation](#thread-creation)); seeds `rng.c`; makes its object
   tables, then fills the time page, a pool page recorded as a memory object and kept until the
   machine ends ([the call table](#the-call-table)); creates its gate, the service
   thread, stopped, with the `sigma0` gate as pager, and the watchdog with its configuration and start
   event (`watchdog.c:127`).
7. Points its own `_pager` and `_exc_handler` at its gate and runs the service and the watchdog.
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
| `flags` | `ERX_BOOT_ROOT`, with `ERX_BOOT_DET` under `erx.det=1` | `ERX_BOOT_ROOT` |
| `pack_flags`, `release_addr` | the handoff's flags; its archive start, which `sigma0` maps one to one | the archive header's flags; the address of its `mmap` |
| `group` | what `erx_group_create` returned | `ERX_CAP_SELF`, which a bind accepts |
| `time_page` | a handle to the time page's object ([the call table](#the-call-table)), which the domain library passes to each domain; the root's own reads find the page with no handle | `ERX_CAP_NULL`: the hosted clock is the host's |
| `space` | `ERX_CAP_SELF`, as every space names itself | the same |
| `budget`, `group_ctl`, `group_stat`, `spaces_group`, `release`, `crash_area`, `system_connection` | `ERX_CAP_NULL` and zeros: `erx_vm_*` and `erx_group_status` find theirs with no handle, `erx_release_entry` reads the archive, and no Phase 1 caller takes the rest | the same |
| `cpuset`, `capacity_mcpu` | the manifest's system share's `cpuset` within what `l4_scheduler_info` reports; 1,000 for each CPU, since Phase 1 has no grants | the host's online CPUs; the same |
| node name | `system@` and the manifest's `host` | the same |
| `args` | the manifest's `system_args`, the console's words, `-erx boot VALUE SLOT` ([image windows](#image-windows)) and each [device record](#device-records), then each `erx.arg=WORD` | the manifest's `system_args`, then `-erx console_driver erx_stdio`, then the command line after the archive's path |
| `env` | empty | empty: the host's environment is not inherited, and the entry sets `TZ=UTC` for libSystem |
| `hwcap`, `hwcap2` | 0, which claims no optional feature; the interpreter asks for none | the same |
| `limits` | the projection of the manifest's `system_runtime_limits` | the same |

`system_args` is a new string of the manifest's header, under the same rule as a domain's `args`, so
the system's start has the one configuration file every other setting has. It holds what `erl_start`
reads, emulator flags, `--`, then `init`'s arguments, with nothing converted on the way
([Configuration](design-runtime.md#configuration)), so what follows it on the page, the driver's name and
the command line's words, are `init`'s arguments. Strings past `ERX_BOOT_STRINGS_MAX` (2,048), or a limits record out of range,
refuses the boot with the reason, as in step 6's failure; ERTS never starts on a
partial page.

A reader, `erx_boot_info_read(page, size, view)`, checks the version, the ABI version, the flags, the
reserved words and every string against the page and `ERX_BOOT_STRINGS_MAX`, and `sys/erxos`'s
`erx_runtime_main` starts ERTS on nothing else. `erx_boot_argv_plan` and `erx_boot_argv_fill` make
[the vector for `erl_start`](design-runtime.md#configuration) from what it accepted. A word list on
the page has no empty word, and an environment word is `KEY=VALUE`. Both the build and the read refuse
anything else with its reason, and a refused build writes nothing.

The page is a page of the root's image, written before any other thread reads it and not read-only:
Phase 1 keeps no isolation inside a task. The launcher writes a test task's page with the same
function and maps it read-only.

**A domain task's page** is the domain library's, built by the same function from what
[Creating a domain](design-system.md#creating-a-domain) gives it, mapped read-only, and passed to the
task's first thread as its argument. Its `flags` carry `ERX_BOOT_DET` when the system's page does. The domain runtime image's
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
fuzz target, splits it on spaces and reads five kinds of word: `erx.watchdog=P,D,B`, through the
existing `erx_watchdog_parse`; `erx.det=1`; `erx.group_report=1`; `erx.hostlink=1`; and `erx.arg=WORD`, at most as many as fit the page's
strings. Other words are ignored, as a boot loader's may be there. A malformed `erx.` word, and an `erx.` word of no known kind, refuses the
boot with a fixed reason. Bootstrap cuts the record at the last whole word, so a parser never sees half
a word.

`erx.group_report=1` is the native form of the hosted backend's `ERX_HOSTED_GROUP_REPORT`. Once the
system's group exists, `liberx/backend/fiasco/park_report.c` starts a worker thread of the root that
looks at the group's status page ten times a second and writes `erx: root task: group: parked N of M`
to the console through `erx_fiasco_console_write` each time the count of parked executors or of
executors changes. The thread only reads the page and sleeps. Both backends' reporters build the
line with `erx_group_report_line` (`liberx/backend/core/group_report.h`), each under its own head;
it is fixed words and two numbers, so it needs no escape, and like a program's output it can fall
between the bytes of the console driver's writes. The production image suite boots with it and waits for `parked N of N`, N the
system's schedulers and dirty CPU schedulers, after the shell's banner and a line typed at the prompt
that keeps one scheduler busy for half a second, so the report must show it wake and park again: M3's
idle machine.

`erx.hostlink=1` asks for the host link: only with it does the root hand the system domain's ERTS the
host link's device record ([Device records](#device-records)). The manifest names the host link's UART
by its device-tree path, and the root does not look in the device tree for it, so on a machine without
that UART the record would point `erx_pl011` at empty address space, whose first read faults the
system domain and with it the machine. Without the record `erx_hostlink` starts nothing and the boot
is the same otherwise. `Erx::QemuPlan` adds the word exactly when it gives the guest the second
`-serial` ([The production image](#the-production-image), "Device paths"); the website's emulator, whose machine has one UART, never
sends it. erXos's kernel needs no such word: it lists a UART only when the device tree has it.

## The Phase 1 manifest check

Two things stop a production image without it: `Admitted.admit` refuses every
manifest for `root_startup` (`manifest.rb`, and `Pack#build` requires the
admitted bytes), and before that `EmptyNative#check` refuses a full boot and
every `domain`, `partial_boot`, `window`, `service`, `facet`, `introduce`,
`image` and `liveness` record. **`Stopgap`** sits beside `EmptyNative` and
shares its readers: a development manifest, full or partial boot, with the
system domain and its configured domains. It accepts the records the system
release's services and the configured domains need, `domain`, `window`,
`service`, `facet`, `introduce` and `image` among them, and refuses
`partial_boot` and `liveness` records with a diagnostic naming the milestone
that brings them. Its `image` records are
format `erofs_unchecked` ([design-abi.md](design-abi.md)): the packer writes no
hash tree, so an image's record carries its data's length and extents, which
the packer derives from the built image, the artifact its `input` names, and
zeros for every tree field, and a `salt` is refused. Each image lies on the
block device, and a `verified_image` window names one image, read-only, held
by the domain the window's record names. The production image's one image
is the system release's EROFS image (`ReleaseMedium`), written before the
archive is packed, since the archive's manifest records it; the image does not
hold the manifest. Phase 1's EROFS windows pass blocks through unchecked; the
hash check is a stopgap residual recorded in `TODO.md`. QEMU `virt`'s record is
[config/platforms/qemu-virt.json](../config/platforms/qemu-virt.json) and its
manifest
[config/manifest/qemu-virt-development.txt](../config/manifest/qemu-virt-development.txt).
Its scope, against
[design-system.md](design-system.md)'s properties, each kept property with a
seeded violation and each refusal with a seeded record:

| Property | Phase 1 | Whole again at |
| --- | --- | --- |
| 1 one holder per device and unit | kept; a holder is the system domain or a configured domain | |
| 2 facets name servers | kept, with introductions: a facet names a service of the manifest, served by the system domain or a configured domain | |
| 3 PCIe configuration space | QEMU `virt` drives no bridge in Phase 1, so no holder is allowed and no `pci` device is placed | M9 |
| 4 budgets and grants sum | kept for `root_memory`, baseline, shares, the configured domains' budgets and grants and `max_domains`; the configured domains' sums are the planner's (property 12); `root_startup` by the rule below. The sums are checked at build time; nothing enforces them at run time ([Budgets and groups as records](#budgets-and-groups-as-records)) | Track K (`root_startup`, enforcement) |
| 5 names | kept | |
| 6 no JIT in the root | kept; a full boot may use the native root image, since the interpreter image is not yet the root | |
| 7 the sealing secret | `sealing` is `none`, no entry carries `ERX_ENTRY_SEAL`, no TPM | M11 |
| 8 partitions and devices reach holders | kept: the UARTs are the system domain's; the slot and data windows are the system domain's or a storage domain's, as the manifest places them; the network device is the system domain's, which runs the network stack until 1b-E, and from 1b-E only the network domain holds it; the display domain holds the gpu and input devices; no vault partition | M11 (vault) |
| 9 a release build's confinement | release builds refused. In a development build every virtio-mmio device is unconfined and allowed, whoever holds it, the display domain's gpu and input devices and the net device among them, which the system domain holds until 1b-E and the network domain from then, as the property's development clause says; the display domain is reported in the trusted base. The packer sets `ERX_PACK_UNCONFINED_DMA` when the manifest gives an unconfined device, as the property says, and nothing reads it | M11 |
| 10 boot order, 11 rescue, 12 child domains, 13 headroom | kept; 12 runs the host build of `erx_dom_plan_configured` in boot order and `erx_dom_plan_connect` over the introductions, recording each plan, as on erXos's kernel, so the configured domains' sums of 4 and 13 are the planner's; 13 is a configuration check and nothing enforces grants at run time | |

**The root startup rule** is a sanity check, not a proof: the root entry's
loadable segments plus `system_baseline` fit `root_memory`, and `root_memory`
fits the platform's RAM less `fiasco_reserve`. `fiasco_reserve` is a number in
the platform record beside `ram_bytes`, the harness's RAM size. `sigma0`'s
resource dump at 512 MiB on a 4-CPU HVF boot of the fork shows 33.8 MiB it does
not offer the root: 32 MiB of kernel memory, the kernel's image, the device
tree's 1 MiB and `sigma0` itself; at 160 MiB the kernel memory is 10 MiB. QEMU
`virt`'s `fiasco_reserve` is 16 MiB, a little more than that. The rule leaves the
archive out: `bootstrap` reserves it whole and it is never released, so a
manifest's `root_memory` must leave it room below RAM less the reserve; QEMU
`virt`'s 96 MiB leaves it 48 MiB. If either is wrong, the pool fails at boot with a
diagnostic. A platform record without these numbers is not admitted. The
`Admitted` value records `root_startup: declared` in its report, and
`erx_root_plan` replaces the rule behind the same value in Track K.

A test task's program is a boot-image entry named by the boot argument
`erx.test=PATH`, not a `partial_boot` record.

## The production image

`Erx::ProductionImage` (`tools/lib/erx/production_image.rb`) builds the image the
system boots from, and `tools/erx pack` and `make check-reproducible` run it. Its archive
comes through `Pack#build`, the one funnel that takes `Manifest::Admitted`, so nothing
reaches it unadmitted. Test images keep `BootImage` and the structural recipe
under `test/fixtures`, which `Manifest::StructuralFixture` feeds; the production path loads
nothing from `test/fixtures`, and `production_image_test.rb` checks the loaded files.

No production image carries test code, by construction rather than by a caller's
convention. `ProductionImage#build` takes no additions: its image holds the system
release, the domain releases and runtime images its manifest names, and nothing else. The one way to add files to that release is the test entry
point, `ProductionImage#build_test_image(directory:, added:, machine:, domains:)`, which packs them with
`ERX_PACK_TEST_CODE` set in the archive's flags. The packer sets the bit only in a
development build, the archive check and the kernel refuse it in any other, the
kernel's banner prints `test image: carries test code` after the development warning,
and the image's `Built` record reports the bit read back from the archive header. The
production boot check refuses an image with the bit and requires the kernel's
`erx: boot image build` line to report the archive's own identity and flags. The
source check (`Checks::TEST_IMAGE_BUILDERS`, the `test-image-builder` chokepoint rule)
fails the build when Ruby under `tools/` other than `ProductionImage` itself and
the two QEMU harnesses that boot test code, `OracleQemu`, the oracle's run, and
`BlockDevice`, the block device suite's, names the test entry point or hands the
packer a literal true for its `test_code` keyword; each harness's boot transcript
checks the banner's test-image line;
`test/host/checks_test.rb` seeds its violations.

A test image may also name a larger machine (`ProductionImage::Machine`): its RAM,
its `fiasco_reserve`, which grows with RAM because Fiasco sizes its kernel memory
as 6% of it, a growth added to both `root_memory` and `system_baseline` of the
development manifest, a growth of `/tmp`'s cap, and the root's place, the one
address `liberx/backend/fiasco/root.ld` takes from the root's link; the rest of the
added RAM widens the archive's room below RAM, up to the root's place. The
development machine links the root 64 MiB into RAM, so it fits 160 MiB, and the
oracle's 2 GiB machine 192 MiB into RAM, which holds the archive to about 187 MiB
([Boot](design-platforms.md#boot) gives the arithmetic).
No other line of the manifest changes, and the manifest check proves the
grown manifest against the platform record with that RAM and reserve as it proves
the development one. The production image always boots on the development machine,
which is the platform record's own 160 MiB and 16 MiB: small, since the browser
emulator's guest RAM is the tab's memory, yet with room to spare at the shell. `OracleQemu` boots on 2 GiB with a
160 MiB reserve, the system domain 1 GiB larger and `/tmp`'s cap 160 MiB, since
OTP's suites ask for more than the development baseline holds (compiler's
`beam_ssa_check_SUITE` asks for a 98 MiB heap) and fill more of `/tmp` than its
16 MiB (stdlib's group charges about 97 MiB).

| Archive entry | Kind | What it is |
| --- | --- | --- |
| `boot_kernel_path`, `boot_sigma0_path` | file | Fiasco's kernel and `sigma0`, as `bootstrap` loads them |
| `boot_stand_in_root_path` | file | the root as an ELF file, which `bootstrap` loads |
| `system/root` | image | the same program as an image, the header's root entry, which the root startup rule sizes |
| `system_manifest_path`, `system/NOTICES` | file | what `Pack#build` generates |
| `domains/<name>/...` | file | a domain release's files, `<name>` the release's name, whose applications the build's release table defines under that name; the index is sorted, so each release is one run of whole entries, which the domain library slices, and none carries the system mark. The release provider strips the prefix, as it strips `system/`. `<name>` is a manifest identifier, and a domain row's `release @artifact.<name>` names the run: its first entry and its count of files |
| `runtimes/emu` | image | the domain runtime image: the interpreter ERTS linked as a task's program at `task.ld`'s fixed addresses, since `erx_image_map` loads only an `ERX_IMAGE_FIXED` image; one image for every domain, named as `erx_domain`'s spec names its flavour, with BeamAsm's beside it as `runtimes/jit`, the one entry whose manifest carries `ERX_IMAGE_JIT`, named `@artifact.jit`. It carries no system mark, since the root does not run it, and a domain row's `runtime @artifact.emu` names it |

The root is stored twice because `bootstrap` reads an ELF file while the archive's
root entry is an image by the validator's rule. Track K's planner loads the image
and the file goes.

**Source records.** The kernel and `sigma0` carry an `assembled` receipt over Fiasco's
own receipt, so their notices come from Fiasco's audit. The root carries a `linked`
receipt over its objects, dependency files and link map. Its dependency files leave out
system headers (Fiasco's and the compiler's). Fiasco's three archives that its link takes
members of are registered whole, with the license of the package they come from, since
their members have no compile record a `linked` receipt could name.

**The root's program.** The root is ERTS's interpreter. `Erx::NativeRuntime` builds it with OTP's own
configure and make from `otp/xcomp/erl-xcomp-aarch64-unknown-erxos.conf` in a private copy, over a
sysroot of musl's headers and the root's libraries, and fails if an object imports a name
`sys/erxos/imports.txt` does not list. OTP's own link of `beam.emu` shows that no name is missing.
`NativeRoot` links the root again from `erl_main.o`, `libbeam.a`, OTP's other archives, `libc.a` and
Fiasco's libraries, without debug information, because its link map is what the root's receipt reads.
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

## The call table

Every consumer kept in Phase 1 has a row, and `ERX_ENOTSUP` answers everything else. This one table
lists calls, refusals and differences. A call that names a space takes `ERX_CAP_SELF` or a space
handle, and a task holds a space handle only for a space it created, since no space handle
passes; so "a space the caller created" is checked by the handle alone. M7's parity review works from its last column: a difference
not listed is a bug in one backend. "Service" and "local" say where the body runs. The hosted
backend carries the rows 1b-A needs where cheap and answers `ERX_ENOTSUP` elsewhere
([The hosted backend](#the-hosted-backend)). One function-API test set, `test/guest/function_api`, runs each case on
every backend that carries its row and seeds Track K's conformance roster. Four rows, `erx_space_create`, `erx_irq_create`,
`erx_cap_pass` and `erx_image_map`, are called from the root in 1b-A, where the domain library runs, and from any task
when a session needs them (1b-B); until then such a call from another task is `ERX_ENOTSUP`. Every other row takes its
callers as it says.

| erXos call | Phase 1 consumer | Body | Result and refusals | erXos's kernel instead |
| --- | --- | --- | --- | --- |
| `erx_vm_reserve`, `_commit`, `_decommit`, `_release`, `erx_space_protect` | musl `malloc`, ERTS allocators, stacks; the domain library and a session's port driver reserving in a space they created | service: [Budgets](#budgets-and-the-ownership-of-pages), over the caller's space or one it created; a task's commits count in the pool's one count ([Reporting a budget](#reporting-a-budget)) | correct contents; `ERX_ENOMEM` from the pool, or with no free range; write and execute together `ERX_EINVAL`; a touch of a decommitted page is a fault; a release over a whole mapping removes it, and a commit or decommit that meets a mapping, or a release that cuts one, `ERX_EINVAL`; a protect that meets a mapping `ERX_ENOTSUP` | lazy population with committed memory reserved (K6); protection beneath a ceiling (K4), so `_RX` over private memory is `ERX_ERIGHTS`; a refused call keeps the parts before it (K6); `erx_vm_reserve` without `ERX_VM_FIXED` searches below the placement base, where this one takes the lowest free range of its area |
| `erx_mem_create`, `erx_vm_map` | a connection's two sides, a domain's boot information page and crash area (the domain library); a channel's rings, a data area and a pipe's rings and lock page (a session); a driver's buffers; BeamAsm's JIT objects; the time page, a group's areas | service: pool pages recorded as an object, all committed and zeroed at creation, charged to the budget named; each map is `l4_task_map` from the window into the space named, at addresses reserved there and neither committed nor mapped, with a mapping record ([Shared objects](#shared-objects-and-the-jit-alias)). Any object a task holds a handle to maps, whoever created it. `ERX_MEM_JIT` only from a task made with `ERX_SPACE_JIT`, else `ERX_ERIGHTS` | any number of mappings, into any task the caller may name; an address, size or offset off a page boundary, or a size of 0, `ERX_EINVAL`; offset plus size past the object's end, computed with checked arithmetic so an overflow is past it too, `ERX_ERANGE`, refused before any page is mapped; addresses already committed or mapped, or outside a reservation of the target, `ERX_EINVAL`; a write right over a sealed or code object `ERX_ERIGHTS`; no pages `ERX_ENOMEM`; `erx_mem_grow` `ERX_ENOTSUP`. An object goes at the first of: its destroy, its budget's destroy, the end of the task that created it, or the moment its last handle and its last mapping are both gone | grow works; an object lives only by its budget and its references, and its creator's end does not delete it |
| `erx_image_slice`, `erx_image_map` | the domain library: a domain's release slice and runtime image; a session's port driver: a program command's slices, the loader `erx_exec`; the test-task launcher | service: a slice is a record of whole entries of the archive, charged to the budget named; `erx_image_map` copies an entry's segments through the window into pool pages of the target space, cleaned and invalidated, code read-execute and data read-write, and returns the entry point; it loads an entry in either of two forms, an image entry (a domain's runtime) by its manifest's segments as `erx_image_plan` plans them, or a file entry holding an ELF executable (the test-task launcher's programs) as `erx_elf_plan` plans it, and refuses an image not linked at fixed addresses with `ERX_EINVAL`, as nothing here relocates; every refusal of an entry is `ERX_EINVAL`, without the kernel's `ERX_ENOTSUP` for another ABI version or `ERX_EEXIST` for a range in use, and a load that fails partway leaves the segments before it mapped until the space is destroyed; `erx_vm_map` of a slice maps the archive's own pages read-only with `l4_task_map` from the root, where `sigma0` mapped them one to one. `erx_image_map` from the root in 1b-A; from any task when a session needs it (1b-B) | a range off entry boundaries, or a file of the system release asked by a task other than the root, `ERX_ERANGE`; a write right on a slice `ERX_ERIGHTS`; destroying a slice revokes its mappings, as any memory object's destroy does | a slice's deletion removes its mappings; slicing is checked against `SYSTEM` |
| `erx_mem_create_paged`, `erx_mem_supply`, `erx_mem_seal` | code objects, which the domain service makes for a session's command server (`erx_dom_code_object`); data objects, which a session's filler makes | service, from 1b-B, whose sessions are the first consumer, and `ERX_ENOTSUP` in 1b-A: a paged object is a shared object with a sealed flag, its pages zero at creation; a supply copies from the source object's window pages into the target's, as `erx_mem_copy` does; a seal sets the flag, and every map and supply reads it, since the service performs every one | a map of an unsealed paged object `ERX_EBUSY`; a supply into a sealed one, and a write right in a map of one, `ERX_ERIGHTS`; a supply whose offset plus length passes the target's end, or whose source offset plus length passes the source's, each computed with checked arithmetic, `ERX_ERANGE`, before any byte moves; a source that is physical memory or a JIT object `ERX_ETYPE`; a supply writes every page of its range, supplied before or not; `ERX_MEM_CODE` from a task other than the root `ERX_ERIGHTS`, since the code right is the system domain's; a seal always succeeds, since an unsealed object has no mapping and so no writer; `erx_mem_dirty`, `erx_mem_child`, `erx_mem_own` `ERX_ENOTSUP` | pages supplied on demand; a supply fills only pages not yet supplied; copy-on-write children (Track Q) |
| `erx_mem_copy` | the domain service reading a crash area; a server reading a client's memory | service: copies between the two objects' window pages, at most 64 pages a request, so the stub loops | either object gone `ERX_ESTALE`, never a fault; an offset plus length past either object, computed with checked arithmetic, `ERX_ERANGE`, before any byte moves; physical memory or a JIT object `ERX_ETYPE`; a sealed destination, or a slice, whose pages are the archive's, `ERX_ERIGHTS` | in the kernel, through its own mappings |
| cache maintenance, the code barrier | BeamAsm | local: asmjit's and ERTS's sequences unchanged ([design-arch-aarch64.md](design-arch-aarch64.md)) | correct | none |
| `erx_mem_create_physical` | `erx_device`: the console UART (M3) and the host link's; through `erx_dom_device_give`, each device's register window for its holder ([Device records](#device-records)) | service, from the root only: `l4sigma0_map_iomem` into the root's device window, over the base and size its caller reads from the manifest's device entry; each map is then `l4_task_map` from there into the space named, as for a shared object; for the console UART also [the handoff](#the-console) | RAM, which `sigma0` keeps, `ERX_ERANGE`; execute `ERX_ERIGHTS`; a full window `ERX_ENOMEM`; a create from a task other than the root `ERX_ENOTSUP`, since the domain library makes every device's objects and passes them | within rights, from a carved resource |
| `erx_mem_create_contiguous`, `erx_mem_dma_addr` | the device NIF's buffers and rings, in whichever domain holds the device | service: a create from the root only, first fit from a [contiguous pool](#the-pool), aligned to its size rounded up to a power of two, at most 1 MiB, wholly below the caller's limit, cached, zeroed, and never given back; the domain library passes it to the device's holder. `dma_addr`, from any task holding the object, is physical address plus offset, since QEMU `virt` as the harness starts it has no IOMMU | no such run `ERX_ENOMEM`; `dma_addr` of another kind of object `ERX_ETYPE`, past the object `ERX_ERANGE`; execute `ERX_ERIGHTS`; a create from a task other than the root `ERX_ENOTSUP`; unconfined; `erx_dma_map`, windows `ERX_ENOTSUP` | through a DMA window (M9) |
| `erx_irq_create`, `erx_irq_bind`, `erx_irq_ack`, `erx_irq_trigger` | device lines, in whichever domain holds the device; a connection's bells; a channel's and a pipe end's doorbells; ERTS's wakes | service: `l4_factory_create_irq` from the root in 1b-A; from any task when a session needs it (1b-B); for a line, from the root only, `l4_icu_bind`; a bind to a group, from the root, gives the object a free entry of the group, records the label and runs `l4_rcv_ep_bind_thread(irq, dispatcher, entry)` on the group's home task's dispatcher once both exist, a bind again to the same group moves the label, and an unbind runs `l4_irq_detach` ([Interrupts and readiness](#interrupts-and-readiness)); the object's destroy runs `l4_irq_detach`; `l4_irq_unmask`; `l4_irq_trigger`. Every call is a request: no IRQ capability is mapped into a task, and a delivery goes from Fiasco to the dispatcher directly | each label once, the line masked until acked; `erx_irq_route` `ERX_ENOTSUP`; a target that is not a group the caller holds `ERX_ETYPE`, or a thread, `ERX_ENOTSUP` unless [vCPU upcalls](#vcpu-upcalls-on-fiasco) are carried; a bind of a bound object to another group `ERX_ENOTSUP`; a bind or an unbind from a task other than the root `ERX_ENOTSUP`; a group's 65th bound object `ERX_ELIMIT`; a line's second object `ERX_EBUSY`; a line created from a task other than the root `ERX_ENOTSUP`; the resource ignored | by capability, without the root; `BIND` and `TRIGGER` split; route applied |
| `erx_group_create`, `_configure`, `_info`, `_take_ready` | the adapter's five changes (M3); the domain library's group and sub-space group for each domain; a session's group for each program | service for `create`, `configure` and `info`, local for `take_ready` in the group's home task: [Budgets and groups as records](#budgets-and-groups-as-records), [Interrupts and readiness](#interrupts-and-readiness). `configure` keeps only the CPU set of the grant in the caller's UTCB, and `info` writes an `erx_info_group` there, with that set as `cpuset` and the home task's status page's `parked` and `ready`, and only their bits of `reported` set, `cpuset`'s only once a set was configured ([Reporting kernel objects](#reporting-kernel-objects)) | correct readiness; everything else `unsupported`; no guarantee, quota or throttling; budget and parent recorded, and a group goes with its budget; every thread of a group runs in one task, its home, so a thread created in another task `ERX_ENOTSUP`; a task's second home group `ERX_ENOTSUP` | grants enforced, usage reported; a group's threads in any space |
| `erx_park`, `erx_executor_wake`, `erx_yield` | ERTS's schedulers (M3) | local: [The park protocol](#the-park-protocol); `l4_thread_yield` | no lost wake; a worker `ERX_ETYPE` | in the kernel, the executor switched |
| `erx_umtx_wait`, `erx_umtx_wake` | musl's futexes | local: [The umtx table](#the-umtx-table) | correct within a task | across spaces; `ERX_EFAULT`, `ERX_ESTALE`, `ERX_EINTR` |
| `erx_thread_create`, `_start`, `_exit`, `_set_affinity` | `pthread_create`, ERTS's threads, `libc-test` | [Thread creation](#thread-creation), [Deletion](#deletion); affinity is `l4_scheduler_run_thread` | no free index `ERX_ENOMEM`; an empty mask, or one naming no CPU, `ERX_EINVAL`; affinity runs the thread on one CPU of the mask, its own if the mask holds it; in a space the caller created, only that space's first thread, so a second `ERX_ENOTSUP`; a start of a thread that faulted `ERX_ENOTSUP`; a thread's own-task handle, and a creator's handle to the first thread of a space it created, names no thread once it is reaped, and the index's next thread after that; `erx_thread_stop`, `_read`, `_write`, `_set_urgency` `ERX_ENOTSUP` | backed and charged at create; any number of threads in a space the caller holds; a start resumes a repaired thread; a reaped thread's handle `ERX_ESTALE`; those calls work; the thread may run on any CPU of its mask |
| `erx_pthread_create_executor` | ERTS's normal and dirty CPU schedulers, through `ethr_thr_create` | natively musl's `pthread_create` with the executor class, in the row above; hosted a start wrapper ([Making an executor](design-runtime.md#threads-and-synchronisation)) | `pthread_create`'s; no free index or slot `EAGAIN` | the same call |
| `erx_release_entry` | `erx_prim_file.c` | in the root and hosted, local: `erx_pack_entry_at` and `erx_pack_path_at` over the archive `erx_pack_open` accepted, counting from the first path under `system/`. In a task, a service request naming the boot information's `release` and the index, answered from the slice's record: `index` counts from the slice's first entry, the path comes without its `domains/<name>/` prefix ([The production image](#the-production-image)), and it arrives in the caller's public UTCB in pieces of at most `utcb_bytes_max` bytes, so the stub loops for a longer one | path, size and offset from `release_addr`; an index past the run `ERX_ERANGE`; in a task, a `release` that is not a slice `ERX_ETYPE` | `erx_object_info(release, ERX_INFO_IMAGE_ENTRY, ...)` |
| `erx_space_create`, `erx_space_stop` | the domain library, for every domain; a session's port driver, for each program's anchor and image; the test-task launcher in the root (`libc-test` M3) | service, from the root in 1b-A; from any task when a session needs it (1b-B): `l4_factory_create_task`, with a handle table of `cap_limit` entries; `parent`, `fault`, `label` and the budget recorded ([Spaces, parents and exit records](#spaces-parents-and-exit-records)); a stop is [task exit](#task-exit) of the space and of every space below it, children first | the exit record at the fault gate once every thread of the space is deleted; a parent other than the caller's space or one it created `ERX_ETYPE`, and in 1b-A a parent other than the root's own space `ERX_ENOTSUP`; a `fault` that is not a gate the caller holds `ERX_ETYPE`; `cap_limit` past `ERX_CAPS_MAX` `ERX_EINVAL`; `ERX_SPACE_JIT` from a task other than the root whose own space is not a JIT space `ERX_ERIGHTS`; `erx_space_pause`, `_resume`, `_clear_caps`, `_quiesce`, `_copy` `ERX_ENOTSUP` | pauses, quiesce, copies; a stop's bounded finishing path (K18) |
| `erx_gate_create`, `erx_gate_bind`, `erx_ipc_wait` | the domain library's fault thread and each domain's gate worker, serving fault gates | service: a gate is a record with a queue of fault and exit records and the one thread bound to it; a wait takes the oldest record, or sleeps on the thread's semaphore until the service queues one ([Fault gates](#fault-gates)) | the record's words in the message registers of the caller's public UTCB, its space's label as the label; the deadline as for every wait; a bind replaces the gate's thread, and `ERX_CAP_NULL` unbinds it, as on erXos's kernel; a bind to a thread of another task `ERX_ENOTSUP`; a wait by a thread no gate is bound to waits until its deadline; `erx_ipc_call`, `_send`, `_reply`, `_reply_wait` `ERX_ENOTSUP`, so no gate carries a message | gates carry messages and capabilities, with `ERX_EDEAD`, labels and deadlines |
| `erx_cap_dup`, `erx_cap_close`, `erx_cap_pass`, `erx_object_destroy`, `erx_object_info` | Erlang NIF handles, the launcher, the inspector; the domain library installing a domain's capabilities (`erx_dom_install`); a session installing a program's budget, group, channel, data area, code objects and pipe ends | service: the handle tables; a pass copies or moves handle entries from the caller's own table into a space it created, from the root in 1b-A; from any task when a session needs it (1b-B) ([Passing a handle](#passing-a-handle)); destroy deletes the Fiasco objects, for memory revokes every mapping first, and for a budget deletes everything charged to it; `erx_object_info` as [Reporting kernel objects](#reporting-kernel-objects) says | a stale handle `ERX_ESTALE`; a handle used after its own close names what its entry names then; destroying a started thread, or a group that still has a thread, `ERX_ENOTSUP`; destroying an object from a task other than its creator's `ERX_ERIGHTS`, since no pass conveys the delete right; a pass from a space other than the caller's own, into its own, or of a space or gate handle `ERX_ENOTSUP`, as is an item naming the type its handle must have; a thread handle is no entry of the table, so no thread passes; a pass stops at its first refused item with that item's error, an item past a full table `ERX_ELIMIT`, and leaves the items before it passed, which the caller undoes (the domain library by its budget's destroy); the topics and fields that section names `ERX_ENOTSUP` or clear | rights, pass sets and the creator's rule; a refused pass moves nothing; transfer at rendezvous; a closed handle `ERX_ESTALE`; a thread ends at once, and a group's destroy ends its threads; every topic, with object ids |
| `erx_budget_create`, `_resize`, `_watch`; `erx_object_destroy` of a budget | the domain library: each domain's own and outer budgets and each connection's child budget; a session: each program's budget; the inspector | service: a budget is a record of its parent, kind, guarantee and cap, with nothing enforced ([Budgets and groups as records](#budgets-and-groups-as-records)); its destroy deletes the budgets carved from it and everything charged to them | a handle per create; resize records the two values; `used` `unsupported`, as every other field, except the root's budget's `used`, partial ([Reporting a budget](#reporting-a-budget)); watch `ERX_ENOTSUP`; no create, commit or carve is refused for a budget's guarantee or cap | exact, all fields, enforced (K3) |
| the time page, `erx_time_set_wall` | ERTS's time, deadlines | service: one pool page, recorded as a memory object of the root budget, holding the scale of the architecture's user-readable counter and the wall offset. The service maps it read-only into every task at the task's creation, at a constant address just above the task area, the thread table and its label page, that no `erx_vm_reserve` hands out; `erx_time_page` returns that address in a task and the page's window address in the root. Reading is local | correct layout; the boot information's `time_page` names the object and nothing maps from it | the runtime maps the page from its boot information's `time_page` |
| `erx_entropy_read`, `erx_entropy_add` | ERTS's `crypto` seed, the host link | service: `liberx/backend/fiasco/entropy.c` over `rng.c`, keyed from the counter alone; each reply holds 16 bytes and each request 32, so the stubs loop | `erx: entropy: quality: low, from the counter alone` in the banner; at most 256 bytes a call; a read the generator cannot serve `ERX_ENOTSUP`; `ERX_ENTROPY_CREDIT` `ERX_ENOTSUP`, since no source is trusted | in the kernel |
| `erx_debug_log`, `erx_log_read`, `erx_log_take` | `liberx`, ERTS's crash path, test tasks; the Erlang log readers, of which `erx_console` alone takes | service: [The console](#the-console) | correct | in the kernel |
| `erx_backend_trace_read`, `erx_trace_read` | `erx_trace_ring:read/3`, for `erx:trace` | local, in the root: [The trace ring](#the-trace-ring) | the root's parks, wakes, IRQ deliveries and task starts and ends, reported by `liberx trace`; a cursor past the head, or `max` of 0 or over 512, `ERX_EINVAL`; an exhausted ring `ERX_ELIMIT`; `erx_backend_trace_read` in a task `ERX_ENOTSUP`; `erx_trace_read` `ERX_ENOTSUP` everywhere, so the kernel's row is `unsupported` | `erx_trace_read` over each CPU's kernel ring; `erx_backend_trace_read` `ERX_ENOTSUP` |
| `erx_watchdog_pet`, the crash record, `erx_machine_end(res, how)` | M3's criteria | pet: a local atomic store in the root, which alone links it (a task's ERTS fails to link, so no task can call it), and hosted `ERX_OK` with no effect. End: [The end path](#the-end-path) | correct, except a kernel hang or a stalled watchdog | in the kernel (K19, K31) |
| a thread's fault | a domain's or a program's fault; a test task's fault | [Faults](#faults-and-the-fault-of-the-root-task) | a fault record at the space's fault gate, thread `unknown`, the faulting thread left waiting; with no fault gate, a crash record and the task's end; the machine's end for the root | with the thread's identity; a fault's queue entry comes from a pool of its space, so a task that reaps faulted threads and faults again can run its own pool out and lose its own records, harming only itself (a residual) |
| `erx_vcpu_control`, `erx_vcpu_resume`; `erx_irq_bind` to a thread | `liberx`'s signals in programs (Track P) | carried only if [the source check](#open-decisions) passes: [vCPU upcalls on Fiasco](#vcpu-upcalls-on-fiasco) | otherwise `ERX_ENOTSUP`, and programs take default signal actions only | the subset of [vCPU upcalls](design-kernel.md#vcpu-upcalls) |
| messages through gates, rendezvous passing, `erx_mem_child`, `erx_mem_own`, `erx_mem_dirty`, `erx_dma_*`, `erx_resource_carve`, `erx_space_pause`, `_resume`, `_quiesce`, `_clear_caps`, `_copy` | none | none | `ERX_ENOTSUP` | supported |

### Reporting kernel objects

`erx_object_info` is a request on the root's service gate, answered from the service's own tables, except its
group topic, which runs `erx_group_info`'s local body. A bit of a report's `reported` field is set only for a field
the backend has with the attribute's full meaning. `erx_info_partial(topic)` (`liberx/backend/api.h`) returns the
fields of a topic the backend counts only partly, whose `reported` bits stay clear; the inspector turns the two
masks into statuses ([design-live.md](design-live.md#inspection-records)). The hosted backend returns the same
masks. The ABI's layouts carry `reported`, but no partial bit and no reporter.

| Topic | Asked on | `reported` | Partial |
| --- | --- | --- | --- |
| basic | any handle | the topic is `ERX_ENOTSUP`, since a handle carries no rights | none |
| machine | the resource, which is ignored; a task other than the root `ERX_ENOTSUP` | `cpus_online`, the count of `l4_scheduler_info`'s CPU map, clear when that call fails; `uptime`, `liberx`'s clock (`erx_fiasco_clock_ns`, the generic timer's virtual count since the counter started, which QEMU starts at reset and a board's firmware at power-on); nothing else, since no machine page is mapped ([Image windows](#image-windows)) | `memory_total` and `memory_free`, the pool's ([Reporting a budget](#reporting-a-budget)) |
| cpu | as machine; a CPU outside that map `ERX_ERANGE` | nothing | none |
| group | `ERX_CAP_SELF` or any group handle the caller holds; any other handle, `ERX_CAP_NULL` included, `ERX_ENOTSUP` | `cpuset`, once a set was configured, `parked` and `ready`, read from the home task's status page, and none of them before the group has a home; not `capacity_mcpu`, since the grant's capacity is ignored, nor `used_ns` | none |
| budget | `ERX_CAP_SELF` in the root, the root's budget; any other handle, and any call from a task, `ERX_ENOTSUP`, which the inspector shows as every field `unsupported` | nothing ([Reporting a budget](#reporting-a-budget)) | `used` |
| thread | `ERX_CAP_SELF` or a live task's space, any other handle `ERX_ENOTSUP`; `index` counts the task's created and started threads in the order of the service's task table, and one past the last is `ERX_ERANGE` | nothing: no state or wait kind, which only the kernel has | none |
| image entry | the boot image | the topic is `ERX_ENOTSUP`; `erx_release_entry` reads the index, in a task through the service | none |

The domain library creates every domain's group, so the root holds a handle to each and the inspector
shows each domain's group. A group's `parked` and `ready` come from its home task's status page, which that
task's own `liberx` writes under the park lock, so for a group outside the root they are what a trusted
`liberx` wrote, and the kernel's own records are a recorded difference. A thread's id is
its index in the service's task table (`liberx/backend/fiasco/service_task.h`), in the root's memory, which only
the service's own bodies change, as they create, start and delete the thread's Fiasco objects. So a thread listed exists, as the
kernel would say, and nothing in a task's own memory, its thread records included, is read for the listing. A
later thread reuses the index once the thread is reaped, where erXos's kernel gives each thread an object id of its
own, a recorded difference.

## Budgets and the ownership of pages

All of this runs on the service, so a page's state changes one call at a time.

### The pool

At boot the root takes all RAM from `sigma0` with `l4sigma0_map_anypage(pager, window_cursor, order,
&phys, order)`: first one 2 MiB superpage for each **contiguous pool** the manifest's device entries
ask for, recording `phys`; then everything else, at 2 MiB until refused and then 4 KiB until refused.
`sigma0` maps RAM read, write and execute (`memmap.cc:96,125`). QEMU `virt` is coherent, so cached
memory serves for devices.

The window starts at a constant of the backend's address layout, above all RAM, and is never unmapped. The
window's first pages hold [the range table's page index](#the-range-table), sized from how many pages the window holds,
and every page after them goes to the pool.
**A page's identity is its window address.** Only a contiguous pool records a physical address. Free
pages are a list threaded through the pages, and a page is zeroed when taken. An exhausted pool is
`ERX_ENOMEM`.

**Device pages lie below the window.** A contiguous pool and the device window sit at constants of the address layout below the window,
and neither joins the free list: giving back a page below the window does nothing, so no way of ending an object can free a page a device
may still write. A physical or contiguous object is the table a shared object is, over those pages, and the index is sized to hold them too.

### The range table

A pure core that builds for the host and returns plans (`liberx/backend/core/vm_table.c`). It holds three
facts: runs and mappings per task, and one index for the machine. The **runs** are the task's reserved addresses, sorted and disjoint, in pool pages the task's record takes as they fill ([Table sizes](#table-sizes)); adjacent runs merge, so a range is
wholly reserved exactly when one run covers it. The **mappings** are the task's mapping records, sorted and disjoint, each an address range inside one run, the object, the offset and the rights it was mapped with; a mapped page is never in the page index. The **page index** is a hash from a committed page's address and its table's label (a task's or an object's) to its
window address and protection. A page absent from it is uncommitted, and has no protection to remember, since giving it access
commits it. Each entry owns a distinct window page and the index has two slots for each page the window holds, so committing
never finds the index full and needs no pages for it, and every probe ends at an empty slot.

A call computes a whole plan (its range, the state each reserved page in it becomes, and the pages needed), refuses it if the pool
cannot cover it, and only then applies it, so a refused call changes nothing. Applying walks the range's reserved pages in ascending
address order and gives each its steps from one table of state against target ([Protection](#protection)): take and zero a page, unmap,
map, give the page back. A map or an unmap the kernel refuses after that leaves no state worth continuing from, and ends the machine with
the reason. Commit and decommit pass over holes, as the kernel's do; a protect that meets a hole is `ERX_ERANGE`. A commit,
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
holder: [handles flow down](#the-phase-1-backend), so every task that holds or maps an object a task created is that task
or one below it, and those end first. A physical object's pages stay the device window's and a contiguous object's are
never given back ([The pool](#the-pool)); a slice's pages are the archive's, which no event frees.

### Reporting a budget

The pool keeps one count, of the pages it handed out and has not taken back, and no count per budget. The budget
topic asked on the root's budget writes that count as `used` with every bit of `reported` clear, and
`erx_info_partial` names `used`, so the
inspector shows it as **partial**, reporter `root pool`, scope "pages of the root's pool: those handed out, carved
budgets' included, and the pool's total and free; not the kernel's or sigma0's memory, page tables or mapping
records", and a reader of the report alone sees `used` as not reported. `kind`,
`guarantee`, `cap`, `carved`, `lent`, `pinned` and `threshold` are `unsupported`, reported as `kernel`'s, since
the kernel interface answers that it does not report them. The reporter of `used` is the stopgap reporter `liberx_pool` of `abi/inspection.txt`, which stands in for `kernel` and
declares that label and scope ([design-abi.md](design-abi.md#inspection-schema)); a record carries it as
`{stopgap, liberx_pool}` ([design-live.md](design-live.md#inspection-records)). The root's count includes the pages
of every budget carved from the root's, which is why it is partial and not the kernel's `used`. The budget topic
asked on every other budget, a domain's or a connection's, is `ERX_ENOTSUP`, so the inspector shows each of its
fields, `used` included, as `unsupported`, since the pool does not count pages per budget
([What Phase 1 defers](#what-phase-1-defers)).

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
program. So the stopgap keeps budgets as **records** that nothing enforces, and keeps the one property those
callers rely on to clean up: **an object goes with its budget.**

* **A budget record** is an object record of kind budget, and holds its parent, kind, guarantee and cap as
  given. `erx_budget_create` makes one under any budget the root holds; `erx_budget_resize` records the two new
  values; neither checks them against the parent, and no create, commit or carve is refused for them. Every
  consumer carves and resizes in the root, so a task's budget call is `ERX_ENOTSUP` and every budget record is the
  root's. A task holds a budget's handle when the domain library's install passes it one, and may hold its last; a
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
  the home of one group at most. `erx_group_create` makes one from the root under any budget it holds, with no
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

Nothing here is a guarantee: a budget's guarantee and cap, a group's grant and the sums the manifest check proves
([The Phase 1 manifest check](#the-phase-1-manifest-check)) bind nothing at run time, and the inspector shows every
field but the root's budget's `used` as `unsupported`.

### Table sizes

The service's tables are pool memory, so the only limits are the pool's and the ones erXos's interface itself has.
Each table is a directory page of window addresses of its pages, and a table that fills takes one more page from the
pool: the task table, the object, budget, group and gate records, each task's handle table, runs and mapping records.
A table never moves, since its pages stay where they were taken, and every reference between records is an index,
since the service keeps no pointer across a receive. A table that cannot grow is `ERX_ENOMEM`.

| Table | Limit |
| --- | --- |
| a task's handles | the `cap_limit` its creator gave `erx_space_create`, which the domain library takes from the domain's runtime limits; past it `ERX_ELIMIT`, as on erXos's kernel; the root's, the pool |
| a task's threads | 128, the most one Fiasco UTCB area holds ([Thread creation](#thread-creation)) |
| a task's home groups | 1, a park record made with the task |
| a group's bound IRQ objects | 64, the ready list's length |
| tasks and memory objects together | 4,096, the page index's labels ([What Phase 1 defers](#what-phase-1-defers)) |
| any one table | 512 pages, its one directory page; the task table's two rows a page make 1,024 tasks, and a task's runs 131,072 |
| everything else | the pool |

The page index stays sized at boot from the window ([The range table](#the-range-table)), which bounds it by
construction.

### Kernel memory and the root budget

Fiasco's objects, page tables and mapping records come from its own allocator, sized at boot, charged to nothing
erXos can see. A call that fails for lack of it is `ERX_ENOMEM`, except a map or an unmap under a [range call](#the-range-table), which ends the machine; exhaustion on a path that cannot fail is inherited.

## Threads, waits and exit

### Scheduling

Fiasco's fixed-priority scheduler schedules every thread; ERTS schedules its processes within them. Every thread
but the watchdog runs at Fiasco's default priority of 1, as the root's first thread and `sigma0` do, so a spinner
never outranks a preempted lock holder on its CPU. The watchdog, which takes no lock, runs at 255.
`l4_scheduler_run_thread(L4_BASE_SCHEDULER_CAP, thread, &param)` starts each thread, with `param` from
`l4_sched_param(priority, 0)` and the CPU mask in `param.affinity`. A thread with no mask set stays on the CPU it
was created on (`scheduler.cpp:98-103`). `erx_thread_set_affinity` before the start takes effect at the start, and after it
moves the thread at once, through the same call.

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
carries no generation and is no entry of the handle table. The two kinds of handle are told apart by value. An entry of
the handle table is its index plus one, so 0 stays `ERX_CAP_NULL` and every entry lies at or below `cap_limit`, within
`caps_max` (`abi/kernel.txt`). An own-task thread handle is `ERX_FIASCO_THREAD_HANDLE_BASE` (`0x800000`) plus the index:
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
index is reused, and then names the new thread, a recorded gap ([What Phase 1 defers](#what-phase-1-defers)). In 1b-A only the root makes a first thread, and another
caller's create in a space it created is `ERX_ENOTSUP`. Its start is a request, and the task's own entry marks record 0
started when the thread first runs, as the root's does, and the trampoline below writes its marker.

**`erx_thread_start`.** The stub moves the record from created to started, and only then writes the marker 1: a start of any other handle
is refused untouched, since a 1 written over the kernel's 0 would lose the index for good. The service, in order:

1. `l4_thread_control_start`, `_pager` and `_exc_handler` naming the task's gate, `_bind(slot, task)`, `_commit`.
2. `l4_thread_ex_regs(thread, trampoline, record, 0)`. The trampoline's address comes in the start request, as each task's image has its own. A task's first thread starts at the `pc` of the starting registers its creator wrote, as on erXos's kernel: the image's entry, which `erx_image_map` returned to the creator, with its argument beside it (a domain's boot information page, a program's channel values). The image's first instructions put the task's first stack and its C entry in the record and go to the trampoline.
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
(`task.cpp:686-699`, `thread.cpp:306`). So exit is one service body, reached by a thread's `erx_space_stop(ERX_CAP_SELF,
status)`, which musl's `exit` does, its creator's `erx_space_stop(task, status)`, a fault in a task with no fault gate,
the destroy of the budget its space was created from, or its parent's exit. In the root it is `erx_machine_end`.

The body walks the tree below the task, iteratively and children first, so a space never outlives its parent, and
runs these steps for each task, a child with the status `ERX_EXIT_PARENT`:

1. **The threads.** First `l4_irq_detach` on every IRQ object bound to the task's dispatcher or to one of its
   threads, whoever created the object, so no delivery is ever bound to a deleted thread; then `l4_task_delete_obj` on
   each thread of the task, newest first, reaper and dispatcher included. Each return means that thread never reaches
   user mode again (`thread_object.cpp:157-166`).
2. **The objects.** Every object the task created goes, once the stop is over (step 3), as the [object table](#shared-objects-and-the-jit-alias)'s third
   row says, its mappings in other tasks revoked first; then its semaphores, gate and home group, as
   [Budgets and groups as records](#budgets-and-groups-as-records) deletes one, its bind records with it, so an IRQ
   object that outlives the task, a connection's bell that the domain library created, is left unbound, and a
   trigger of it waits at the object; then the task object, which unmaps everything before the call returns (`task.cpp:686-699`).
3. **The memory.** Its pages return to the pool; each of its mapping records is dropped from its object's list, which
   frees an object whose last reference that was; its handle table is emptied, each entry dropping its object's count,
   and freed with its runs. The objects of step 2 and those whose last entry this drops are only marked here: the
   service ends the marked objects once the request or fault that stopped the task is over, every space of the
   stop walked and every row reset, and before it answers, so an end that stops further spaces, a budget's
   included, never runs inside another task's end.
4. **The status.** The exit record, an `erx_fault` of kind `exit` with the first stop's status, goes to the space's
   fault gate ([Fault gates](#fault-gates)), after step 1, so it comes only once no thread of the space can run. A
   test task, which has no fault gate, gives its status as a test's transcript line: the end ups a semaphore of the
   root's, and the launcher's `erx_fiasco_task_join` asks the service, which answers `ERX_EBUSY` with the task's index
   while the space runs, so the stub waits on that semaphore and asks again; the second answer takes the status,
   deletes the space with every space below it, freeing their labels, and closes the root's handle. A space that
   held the last handle of the budget it is charged to goes with that budget once its stop is over, and as every
   deletion does, the deletion withdraws its exit record: its creator sees no record, and a join answers `ERX_ESTALE`.
   A thread that stopped its own task gets no reply.

**A request cannot race this.** The service runs each request or fault to completion before it receives the next, finds
the task from the gate's label and each handle in that task's table, and keeps no pointer across a receive. Fiasco IPC
queues no messages: a request is a live thread blocked on the gate, and deleting the thread removes it. So once a stop
returns to the receive, nothing can name that task, and its label is reusable once its exit record or status is taken.
A space handle in the creator's table names the stopped space's record until the creator closes it, and its generation
makes it `ERX_ESTALE` once the record is freed.

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
| `mmap`, `mprotect`, `munmap` | `erx_vm_reserve`, `erx_space_protect`, which commits what it makes accessible, `erx_vm_release` | anonymous memory only, a file mapping `ENOSYS`; no type `EINVAL`; a flag other than the type, `MAP_ANONYMOUS`, `MAP_FIXED`, `MAP_NORESERVE` and `MAP_STACK` `EOPNOTSUPP`; write and execute together is `EACCES` |
| `brk` | reports no room | mallocng uses `mmap` alone |
| `__clone` | `erx_thread_create`, `erx_fiasco_thread_set_clear_word`, `erx_thread_start` | only `CLONE_THREAD`; a worker, or an executor with `ERX_CLONE_EXECUTOR`, which only `erx_pthread_create_executor` causes |
| `exit`, `__unmapself` | `erx_thread_exit`, `erx_thread_exit_release` | |
| `exit_group` | `erx_space_stop(ERX_CAP_SELF, status)` | whoever started the program reads the status's low byte; in the root the stop is `erx_machine_end` |
| `clock_gettime`, `nanosleep`, `clock_nanosleep` with no flags | `erx_fiasco_clock_ns`, a timed umtx wait | `CLOCK_REALTIME` reads the clock from boot: Phase 1 has no wall clock |
| `sched_setaffinity` | `erx_thread_set_affinity` | a mask's first word |
| `sched_getaffinity`, `prctl` | not offered: `ENOSYS` | so `sysconf(_SC_NPROCESSORS_*)` answers musl's default of 1 in any program, and `pthread_setname_np` on the caller fails, which ERTS ignores; ERTS counts CPUs from the boot information page |
| `write`, `writev` to 1 and 2, `ioctl` `TIOCGWINSZ` on them | `erx_fiasco_libc_write`: the root's (`libc_root_write.c`, alone in its file so that musl's reference pulls in the console and not the start path) to `erx_fiasco_console_write`, a task's through the service ([The console](#the-console)) | the bytes go out unchanged, as on UNIX; other descriptors are `EBADF`; the size reads zero, which keeps stdio line buffered |
| `set_tid_address`, `gettid` | `erx_fiasco_thread_set_clear_word`, the index plus one | |
| `getpid`, `getppid`, the user and group identifiers | 1, 0 and 0 | fixed values: Phase 1 has no processes and no users, so every task reads the same |
| `sched_yield` | `erx_yield` | |
| `set_robust_list`, `get_robust_list` | the calling thread's list head, kept in musl's `struct pthread` | kept and never walked: musl walks the list itself at thread exit, and only a task's death would need a kernel's help; a size other than Linux's three-word head is `EINVAL`; another thread's list is not offered: `ENOSYS` |
| `rt_sigprocmask`, `tkill` of `SIGCANCEL` | answered with no effect | the signal mask reads empty |

Everything else is `ENOSYS`. No signal is delivered, so `pthread_cancel` returns 0 and acts at the target's next
cancellation point rather than interrupting a call it is blocked in.

`liberx/backend/fiasco/libc_start.c` calls `__libc_start_main` with one argument, no environment and the ELF headers,
which `root.ld` and `task.ld` load first so that musl finds the TLS image. On a root, `libc_root_start.c` first moves off the image's
64 KiB start stack onto 1 MiB from the pool, with a reserved page below it that nothing commits, so an overrun that touches
that page faults instead of overwriting `.bss`, and it ends the machine if the start comes back. A test's root that has no
archive brings the service up in `libc_root.c`, and the system's root in `root.c`. `libc_task.c` is a task's `erx_task_main`,
whose thread `task_start.c` has readied, and it runs on the stack `task_start.c` gave it. A program's own thread handle is its index in the root and in a task alike, so the seam is one file for both.
The program links with `libl4sys.p.a`, which defines four symbols and needs none, and with Fiasco's `libgcc.a` for
binary128 arithmetic.

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
have, and why; a failed line also pins the places in libc-test's source that the test's error lines name. The reason is a stopgap difference this document states, musl's own behaviour with its source cited, a bug with its
`TODO.md` item, or, for a test not run, the cause the plan names. A test the table does not name must pass.
`check-libc-test` fails on any result that differs from its line, a failed test that reports a place its line does not
list, a test not run for another cause than its line's, a line naming no test, a boot that leaks the pool, and a boot that
never says whether it did, so a test that starts to pass needs its line removed. The stopgap's
differences are the two cancellation tests, which no signal interrupts, and the priority-inheritance tests, whose futex
probe reads `ENOSYS`; the oom tests need `RLIMIT_DATA` through `t_memfill`, and are not run.

## Interrupts and readiness

A group's readiness lives in its **home task**, the task its threads run in ([Budgets and groups as
records](#budgets-and-groups-as-records)): the task's one **park record** holds executor slots, status page, park
lock, parked list, ready list and listed flags, and the task's **label page**, committed with the task right after its
thread table at a constant address, holds for each of the group's 64 entries the label `erx_group_take_ready` returns. The executors that park on it, the semaphores they wait on and the
dispatcher that triggers it are all the home task's, so the park protocol below runs inside one task, as it does in the
root.

* **The dispatcher**, one per task, blocks in `l4_ipc_wait`. Every message is one IRQ object firing, whose Fiasco label
  names an entry of the task's home group. It runs a trigger for that entry and waits again, for a device
  line and a software `l4_irq_trigger` alike. The task's own backend initialisation creates it, and its creation tells
  the service the thread's index.
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
  again. Only the root binds and unbinds. A delivery already listed
  under an entry that is then reused reaches its new sink as one look, which every sink treats as a hint
  ([design-domains.md](design-domains.md#connections)).
* **A trigger and an ack** are service requests from any task holding the object, `l4_irq_trigger` and
  `l4_irq_unmask`; no IRQ capability is mapped into a task, so a doorbell costs one service round trip at its ringer,
  and Fiasco then delivers it to the dispatcher directly.
* **The ready list** is an array in firing order, which a take shifts down. It has one entry per bound object, of at most 64, and an object is on it at most once, by its listed flag, so it
  cannot overflow and a trigger allocates nothing. A fire the dispatcher has not received yet is one delivery however often it
  repeats (`Irq_sender::queue`, `irq.cpp:984`), which the listed flag would report as one anyway.
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
`ERX_ENOTSUP` and whose writes do nothing, as only the root links `erx_watchdog_pet`, so a task has no ring.

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

**Reporters.** The ring's records carry the stopgap reporter `liberx_trace`, declared in `abi/inspection.txt` as standing in
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
its own. It is this stopgap's internal wire, not a seam: no number or layout reaches a caller of the function API,
and erXos's kernel has none of it, so [Transport](#transport) records it as a difference and not as ABI to keep.

| Message | Tag label | Words |
| --- | --- | --- |
| request | its `fiasco_call` number | `mr[0]` the caller's thread index; `mr[1..]` the rest of the request's layout |
| reply | zero | `erx_fiasco_reply`: `mr[0]` the status; `mr[1]` and `mr[2]` the results |
| fault | Fiasco's negative `L4_PROTO_PAGE_FAULT` or `L4_PROTO_EXCEPTION` | as Fiasco sends them |

**Payloads never cross the native UTCB.** What the ABI puts in the caller's UTCB (the bytes of `erx_debug_log` and of a task's `task_write`, up to
`utcb_bytes_max`; starting registers; results larger than the registers) stays in the caller's public UTCB, which the service reads
and writes through the window, by the index in `mr[0]`. So 63 message words are always enough. The ABI's memory windows are reached
through the object's window addresses. The caller's task can write its public UTCB while the service reads it, so the decoder
copies what a request takes from it, the length first and then at most that many bytes, into the service's own buffer once, and
every check and the body read only that copy; nothing is read from the public UTCB a second time for the same request.

**The loop.** `l4_ipc_wait`; decode; run the body; `l4_ipc_reply_and_wait` with `L4_IPC_SEND_TIMEOUT_0`. A body never calls a stub.

**Refusals.** A label naming no live task is dropped with a counted diagnostic and no reply. An unknown call number, a word count
that differs from the ABI's, a thread index past the table or a payload length past `utcb_bytes_max` is `ERX_EINVAL`; a call without a
row is `ERX_ENOTSUP`. The decoder has a fuzz target. Addresses cross as values, and the service never loads through them.

### Spaces, parents and exit records

`erx_space_create`, from the root in 1b-A and from any task when a session needs it (1b-B), makes a task and a **space record**: its budget, its parent, its fault gate, its label, its
flags, its handle table of `cap_limit` entries, and its list of children. In 1b-A the parent is the root's own space, and from 1b-B, where sessions make sub-spaces, it is the caller's own space or a space the
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
per thread and one per space it serves. On the stopgap, Fiasco's fault message names only the task, so a fault's entry
comes from a pool belonging to the space and its record's thread is `unknown`; a task that reaps a faulted thread and
faults again can run its own pool out and lose its own records, and only that task is harmed, a residual that goes with
the stopgap.

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
* **Withdrawal.** A space's deletion withdraws its queued records, which on the stopgap happens at `erx_fiasco_task_join`,
  at the release of its space record (its last handle's close, or its creator's destroy or end), at the deletion of a
  space above it, or at a failed create, and not at the stop; a gate's destroy drops its queue and leaves its spaces
  with no fault gate, as on erXos's kernel: their later records are dropped and counted in the space's `dropped` counter, which the inspector reads, a thread that
  faults then stays blocked, and the space's other threads run on until its creator stops it. No Phase 1b caller reaches
  that state while a space lives: the domain library's gates last as long as the system domain, and a session's gate goes
  only with the session's task, whose end stops its programs first. A child stopped by its parent's end posts its exit
  record to the parent's gate, which the same walk then deletes; the record goes with the gate, since its reader is gone.

A space created with `ERX_CAP_NULL` as its fault gate, as the test-task launcher creates them, has its fault end it at once
with a crash record through `l4_vcon_write`, and its status reaches the launcher's join, as below.

### Passing a handle

`erx_cap_pass(from, to, n)` is carried in its creator's case only: `from` is the caller's own space and `to` a space the
caller created. The domain library so gives a domain its budget, groups, connection sides and bells, time page, release slice
and devices (`erx_dom_install`), and a session gives a program its budget, group, channel, data area, code objects and pipe
ends. In 1b-A the caller is the root; a pass from any task comes when a session needs it (1b-B). The body takes the
`n` items, at most `ERX_MSG_CAPS`, in order. They are `erx_msg_item_t` in the caller's public UTCB, as on erXos's
kernel: a descriptor holding the item's rights mask and its move bit, and the handle, copied once and read only there.
For each item the body checks the descriptor (any other bit set is `ERX_EINVAL`, and a type it names, which makes a
checked pass, `ERX_ENOTSUP`), the handle and its kind, and room in
`to`'s table, then copies the entry and rewrites the item in the caller's UTCB with its value in `to`, its type, and
its rights: the mask intersected with what the type carries, less `DESTROY`, since only an object's creator destroys it here.
So rights only shrink in what the call reports, as on erXos's kernel. At the first item it refuses it stops and
returns that item's error, leaving the items before it passed; the caller undoes them, the domain library by
destroying the budget the creation was charged to, as a session does with a program's. A copy adds an entry naming
the same object record, which raises the object's count of handles; a move is a copy and then a close of the
caller's entry. erXos's kernel checks every item before any moves, so a refused pass moves nothing there. No Fiasco capability moves, since every Fiasco capability stays the root's.

What it leaves out, each refused with `ERX_ENOTSUP`, has no consumer: a pass from a space other than the caller's own, a
pass into the caller's own space, and a pass of a space or gate handle. A budget or a group handle passes, for the
domain library's install; a task that holds a budget's last handle ends that budget after its own end, not inside it
([task exit](#task-exit)), so the sweeps above never meet a space whose end is under way. A thread handle is no entry of the table ([Thread creation](#thread-creation)),
so the body reads an item only as an entry of the caller's table and never passes a thread. These are the passes through which a handle
could reach a task that is not below the object's creator, so leaving them out is what keeps
[handles flowing down](#the-phase-1-backend), and with it the safety of deleting an object at any moment; a row that
passes at a rendezvous would let a handle reach a task outside the creator's tree, and that argument would have to be made
again. The rights an item comes back with are recorded nowhere, since a handle carries no rights, and no other call
checks them: the domain library's and a session's masks are their own discipline on this backend, so a holder that maps a side writable it should only read,
binds a bell it should only trigger, charges a budget it was passed without `ALLOC` or `SPACES`, attaches a thread to a
group passed without `ATTACH`, or ends a budget by the close of its last handle without `DESTROY`, is stopped by nothing
here.

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
limits (no write over a sealed object, a code object or a slice, no execute over device memory), and records no right for
the handle. So a connection's side has one writer because the reader's `liberx` maps it read-only, which holds for every
runtime that goes through `liberx` and binds nothing that bypasses it.

The memory every one of them shares is mapped by the service from its window, so a page has one window address whoever maps
it ([One page, one address](#the-phase-1-backend)), and nothing copies. The data path makes no service request while the
other side is awake, as on erXos's kernel: a request is made only to ring a bell, and a ring is one round trip on the one
service thread ([What Phase 1 code must not assume](#what-phase-1-code-must-not-assume)).

### vCPU upcalls on Fiasco

Carried only if [the source check](#open-decisions) passes; otherwise `erx_vcpu_control`, `erx_vcpu_resume` and a bind of an
IRQ object to a thread are `ERX_ENOTSUP`. If carried, the body is this:

* **Arming** runs Fiasco's `vcpu_control` on the thread with a Fiasco state area the backend keeps beside the thread's record,
  with every state bit that diverts faults or selects vCPU user mode clear, so faults still reach the task's gate and from
  there the fault gate. The ABI's `erx_vcpu` area stays the public one in the thread's record.
* **A bind to a thread** runs `l4_rcv_ep_bind_thread(irq, thread, label)` on that thread, outside the dispatcher.
* **An upcall** enters a backend entry, which copies Fiasco's saved state into the public `erx_vcpu` area in the ABI's layout,
  sets `saved_state` and the label, and enters the program's `entry`; nothing of Fiasco's layout reaches it.
* **`erx_vcpu_resume`** validates the public frame, writes it into Fiasco's area and resumes through Fiasco's resume, which
  takes a delivery queued meanwhile as a new upcall.

Each step is conditional on what the check finds, and a step the check cannot confirm makes the whole row `ERX_ENOTSUP`, since
a partial upcall would lose signals.

### Faults, and the fault of the root task

A fault is one more message to the service, which never answers it, because every committed page is already mapped. It names the task,
by the gate, and not the thread, so a record's thread field is `unknown`, and it carries the address and instruction pointer.
A page fault is recorded as kind `memory`, with the low three bits of Fiasco's fault word in `cause`, where bit 1 says the access was a
write. Every exception is recorded as kind `undefined`, with the architecture's syndrome in `cause`: the record is for a reader, and
Phase 1 acts on no finer kind.

* **A domain's or a program's fault:** the fault record goes to the space's [fault gate](#fault-gates), and the faulting thread
  stays blocked in its fault message, which nothing answers, until its space stops; the space's other threads run on, as on
  erXos's kernel. The gate's server stops the space, which posts the exit record. `erx_thread_start` of the faulted thread,
  which on erXos's kernel resumes it after a repair, is `ERX_EINVAL` on the stopgap, since the service cannot tell which
  thread faulted and only created threads start; nothing here repairs a fault.
* **A test task's fault**, in a space with no fault gate: the record goes out through `l4_vcon_write`, then [task exit](#task-exit), with a status of -1. The machine continues.
* **The root's fault:** [the end path](#the-end-path).
* **The service's own fault** goes to `sigma0`, which repairs nothing: a recorded gap.

## The watchdog, the crash record and the console

### The watchdog

A root thread at priority 255 runs `watchdog.c`'s step machine: sleep one period, step over the pet word, which holds the time of the last pet.
In deterministic mode the step is off and the machine page says so. A missed pet takes the end path, with `ERX_END_OFF`, as a root fault does.

Its numbers and mode come from [the command line](#the-command-line), with the design's defaults of 1, 5 and 60 seconds. **The pet is the design's
own**: `erx_watchdog`, a process at priority `max` of the release's `kernel`, started among `kernel`'s first children, right after `on_load` lets a module with a NIF load, calling the watchdog NIF from a
normal scheduler every half second, shorter than any `P` or `D` the command line can set, since those count in seconds. It pets unconditionally and reads no `liveness` record, which `Stopgap` refuses until it does, so a pet says only
that schedulers run and timers fire, and a release with no services is no special case: the first pet follows the first period. Until then the boot races `B` alone, from the watchdog thread's start, which covers ERTS's start,
`init` and `kernel`'s start up to that process. A hang in any of them ends the machine with a crash record at `B`, as it should.

The root itself never pets on ERTS's behalf: a pet must mean that schedulers run and timers fire. The harness gives QEMU `-append` from one table: TCG
`erx.watchdog=1,30,600`, HVF the defaults, deterministic runs `erx.det=1`. A run's own deadline is at least `B + P + 60` seconds, so a stuck boot ends in the
crash record rather than in the harness's kill: the deadline counts from QEMU's launch and `B` from the later start of the watchdog thread, a missed
`B` is seen at the next tick (`watchdog.c:159-163`), and the record takes time to print. The 60 is a test margin, not a promise about the boot. The time to the first pet is about the time to `erx_console`'s banner, which `production_image`'s report holds under both accelerators. A first pet past 60 seconds under HVF is a finding to explain, not a number to raise.

### The end path

A root fault, the root's own stop and `erx_machine_end` reach it on the service, a missed pet on the watchdog. It is best effort and takes no lock.

1. **One caller.** An atomic exchange of the `ending` word; the loser sleeps forever.
2. **The log.** On the service, which alone writes the log ring, lines the console has not taken go out through `l4_vcon_write`. On the
   watchdog the service may be mid-write, so the ring is skipped.
3. **The record.** After a fault or missed pet, the crash frame that [design-kernel.md](design-kernel.md) defines and
   `tools/lib/erx/crash_frame.rb` reads, through `l4_vcon_write`. No thread is stopped first.
4. **The end.** `l4_platform_ctl_system_shutdown(L4_BASE_ICU_CAP, reboot)`, with `reboot` 0 for `ERX_END_OFF` and 1 otherwise
   (`platform_control_object.cpp:88`). Under `-no-reboot` this ends QEMU. If the call returns, the thread sleeps until the harness's
   deadline.

### Device records

The root hands the system domain's ERTS a record of each device the manifest places, as it hands it
the console's words, and the records are the device service's catalogue, which on erXos's kernel
comes from the root resource's device list: for each device of a unit the manifest gives to
any domain, at a device-tree path, whose role and compatible string are a row of the kinds table in
`liberx/backend/core/boot_manifest.c`, it adds `-erx device ROLE PERIPHERAL BASE SIZE LINE
DMA_MEMORY`. ROLE and PERIPHERAL are the row's names, PERIPHERAL the peripheral's name in
the CMSIS-SVD source that `erx_device` opens it as; the numbers, in decimal, are the
manifest's device entry: its register window, its interrupt line and the DMA memory the
platform reserves for it. The rows are QEMU `virt`'s virtio-mmio transports, each with
compatible `virtio,mmio` and peripheral `virtio_mmio`:

| Manifest role | Record role | Holder in the development manifest |
| --- | --- | --- |
| `block` | `block` | the storage domain, or the system domain when no storage domain is configured |
| `network` | `net` | the system domain, which runs the network stack and its driver until the network domain exists at 1b-E; then the network domain |
| `gpu` | `gpu` | the display domain |
| `input` | `input` | the display domain |

Until 1b-E builds the network domain, the system domain runs the network stack, `erx_net`,
and its virtio-net driver, as it runs the block driver until a storage domain is configured:
the development manifest gives it the `net` record, and its `system_args` name
`erx_virtio_net:interfaces/0` for the stack's interfaces. The stack's packet parsers then run in the trusted base. The system
release starts `erx_net` as a `temporary` application, so the stack's end, a crash loop a
packet provokes included, is reported and ends neither the system domain nor the boot; a
machine without the device boots the same, with no interface.

`gpu` and `input` are values of the manifest's `mf_device_role` beside `network` and `block`, since
the manifest check reasons about a display domain's devices by role
([design-system.md](design-system.md#the-manifest), property 9). A further kind of device is one more row.

**A device the system domain holds**, the console's UART, the host link's and a block device
with no storage domain, its driver opens from its record as below. The host link's UART has a
record only under `erx.hostlink=1` ([The command line](#the-command-line)). **A device another domain
holds** reaches it as on erXos's kernel: the device service calls `erx_dom_device_give`, whose
body on this backend creates the register window with `erx_mem_create_physical` over the
record's base and size, the line's IRQ object with `erx_irq_create`, and the device's contiguous
memory at its first give, all in the root, and passes them to the holder; the holder's driver
gets their values over the system connection, maps the window, binds the line to its own group
and acks it ([design-runtime.md](design-runtime.md#the-device-nif), [design-system.md](design-system.md#devices)).
No device call is made from a task other than the root, except a map, a bind, an ack and
`erx_mem_dma_addr` on objects the holder was given. Every such device is unconfined: its holder
reaches any physical address through its DMA, which the manifest check allows in a development
build alone.

**A holder's end and its restart.** A device's objects are the root's, so the holder's end deletes none of them: its
mappings go with its task, and its line's bind goes with its group ([Task exit](#task-exit)). At the holder's exit record
the domain library deletes the register window's object and the line's IRQ object, and keeps the contiguous memory, the
device's for the boot, as [design-system.md](design-system.md#devices) says; the restarted holder's give creates the
window and the line's object again and passes the same contiguous memory. A register range stays in the root's device
window for the boot once `sigma0` gave it, so a create over it maps from the window again and asks `sigma0` for nothing;
two devices whose ranges overlap are refused above this backend, by `erx_dom_device_give`. The new driver resets the
device before it posts anything, so what the old holder left in the device or its memory is not trusted.

Which of QEMU's 32 virtio-mmio transports is which device is configuration: the platform
record names a transport for each role, the bus the harness pins that role's device to,
and the manifest's unit says who holds it. A 4 KiB page holds eight transports and is one
device's alone, since `erx_device` opens and maps a device's registers by the page and
refuses a second device on an open page, so each role takes its own page: the disks the top
page, `/virtio_mmio@a003e00` for the first and each next disk the transport below it, and
the network device the page below, `/virtio_mmio@a002e00`. The production image suite checks each
path, base and line against QEMU's own device tree, as it checks every recorded path. The
root reads no register to choose, since only `erx_device` touches a device's registers; the
driver's first reads of the transport, its magic, version and device id, say whether its
device is behind it. A manifest with no such unit has no record, and a machine without the
device boots the same, with nothing for its driver to drive.

A driver finds its records with `erx_device_record:find(Role, Peripheral)`, which returns
each as a spec for `erx_device:open/1`, with `dma_memory` beside the window and line, and
`{ok, []}` when there is none. Words after the four numbers are not the record's. Each number must be decimal within its field (64, 64, 32
and 64 bits), or the records of that role and peripheral are refused with a stated reason
(`erx_device_record:find/3`, which has a fuzz target). The hosted entry adds no record,
since a hosted runtime has no devices. More records than `ERX_BOOT_DEVICES_MAX` refuse
the manifest at boot.

### Image windows

Phase 1 maps no machine page to the system domain, so the root hands its
ERTS the boot value and slot as it hands it the device records: from the
handoff, which bootstrap derived from `/chosen/bootloader`, it adds
`-erx boot VALUE SLOT`, by the names of `include/erx/core/boot_pair.h`
(`unknown none`, `normal a`, `trial b` and so on). The hosted entry adds
none, which reads as unknown.

Once the partition table is admitted, `erx_blk_service` reads the
release's manifest (`/manifest`, the archive's `system/manifest`) with
the generated reader, and its pure core, `erx_blk_image`, places each
image the system domain holds a read-only `verified_image` window on in
the booted slot: the image's one extent becomes a window of role
`{image, Name}` on the slot's sectors from `slot_offset`, `length` bytes
long, which must be whole sectors inside the slot and the image's
`data_bytes`. A boot with no slot, an unknown boot, serves no image
window, as the storage design requires; an image of another format, in
more than one extent or outside the slot is refused by name in the
kernel log, and the other images are served. An image window refuses
every write with `erofs`.

`erx_blk_sup`'s next child mounts each image window at `/images/NAME`
with `erx_ns:mount({erofs, Window}, ...)`, read-only and unchecked, as
the image's format says. `/images/` is Phase 1's place for the system
domain's own images; the system domain still starts from the release in
the boot image and reads the slot's image as files only, never as code
([design-live.md](design-live.md#invariants) V5).

### The console

The native boot's console driver is `erx_pl011`, which the manifest's `system_args` name with `-erx console_driver erx_pl011`. The root adds `-erx console_uart BASE SIZE LINE`, from the device entry `machine.console` names, and the driver opens that window and line through `erx_device`. It takes exactly one such entry, each number in decimal within its field of the boot manifest's console (64, 64 and 32 bits), and stops with a stated reason otherwise (`erx_pl011:console_uart/1`, which has a fuzz target). A plain `erx.arg` word that joins any of these lists of arguments, the console's or a device record's, is ignored.

Without `-serial_input`, `Config::serial_input` stays `Serial_no_input` (`config.cpp:246,278-282`), so the kernel never attaches the UART's
receive line, which `Irq_chip_gen::attach` would refuse the driver (`irq_chip_generic.cpp:77-81`). Without JDB a kernel panic halts and the
harness's deadline ends the run.

**The sink** is a variable the service owns. `erx_debug_log` copies `len` bytes from the caller's public UTCB, escapes them, and writes to
`l4_vcon_write` on `L4_BASE_LOG_CAP`, the kernel's polled UART output, or to a ring of `log.c` records. `erx_log_read` runs `erx_log_copy` into
its window for a log reader of the root, and `erx_log_take` runs it for the console. The window is the root's own memory, which the service shares and writes in place, so a task's read or take is `ERX_ENOTSUP`; the reply's three words are the next cursor, the records lost and the bytes written. The log keeps one position of what has been taken, which only the early console and the console's take move. The early console takes each record as it writes it. The handoff is the console driver's first map of the UART, in `erx_fiasco_task_mem_physical_body`, after which the service writes no record to the UART and records wait in the ring. From then on `erx_console` polls `erx_log_take`, which copies the records nobody has taken and takes them, and writes each line the log core rendered, escaped, to its driver; taking the log back at the machine's end hands the UART back to the early console, which writes the records past the position and then each new one. So a record reaches the UART exactly once and in order across both changes of taker, with no cursor for the console to learn, and a ring that wraps while parked costs a line saying how many records were lost. Every other reader, such as `dmesg`, reads with `erx_log_read` from a cursor of its own, as on erXos's kernel ([design-kernel.md](design-kernel.md#console-log-and-panic)): a read changes nothing the console or another reader sees, a cursor older than the ring's oldest record is told how many records it lost, and a cursor past the end of the log, the number the next record will get, is `ERX_EINVAL`. A read from 0 also returns the records the early console already wrote; when hosted that is every record, since standard error shows each one as it is written. The two reads are two calls rather than modes of one, so the take's request has no cursor to misread and no cursor value means "take". The service is the serialization `log.h` requires.

**A domain's runtime** writes its standard output and standard error as records: `domain_entry.c` gathers each thread's bytes
into lines with `erx_line_gather_write` and logs each line, without its newline, through `erx_debug_log`, so the log escapes it and
labels it with the task's space, and once the console driver holds the UART, `erx_console` writes it whole between the driver's
other writes ([design-runtime.md](design-runtime.md#the-console-and-standard-io)). ERTS writes standard error a format fragment or a
byte at a time, so passed on as written, each byte would be a call of its own, falling between the driver's. A line longer than
`utcb_bytes_max` goes out in pieces of that size, one record each. A boot information page the entry refuses, before musl
starts, has its reason logged the same way, gathered apart, as the first thread has no thread-local storage yet. Standard output
and standard error share a thread's line, and a line still unfinished when its thread or the task ends is dropped. The system domain's runtime is the root, and its output is the root's, below.

**A program's standard output and standard error** deliver its bytes unchanged, whoever holds the program. The root writes them
to the console itself. A task holds no log capability, so `libc_task.c` hands them to `erx_fiasco_task_write`, one `task_write` call
per `utcb_bytes_max`, and the service copies each piece from the caller's public UTCB to `erx_fiasco_console_write`: no record, no
escape and no rate limit, because a program's own output is not text attributed to a source: as on UNIX and QNX,
`write` delivers its bytes unchanged to the console, which does only a terminal's processing. The pieces of a long write are separate calls, so
another thread's output can fall between them. A shell or session may filter what it displays; `write` does not. Program output
goes to `l4_vcon_write` whatever the sink is, as the ring's records have no form for unchanged bytes, so it can interleave with
the driver's writes at any byte ([design-runtime.md](design-runtime.md#the-console-and-standard-io)).
`erx_debug_log` is the other way out: a program that wants a labelled, escaped record calls it, and `write` never does.

Fiasco's own console (`glue_libc.cc`) puts a carriage return ahead of every newline, whoever writes it, as a terminal's output
mapping does. That is the one difference between what a program writes and what the serial log holds.

**The handoff.** The `erx_mem_create_physical` body for the manifest's console UART maps the UART, and on failure returns with the sink
unchanged; it then sets the sink to the ring and replies. The driver's first touch of a register needs that reply, so it follows the service's
last `l4_vcon_write` of a log record; a program's output goes on as above. A partial boot never maps the entry, so its log lines reach the UART for the whole run.

## littlefs in the system domain

**The port.** Where a storage domain holds the data window, littlefs is that domain's sub-space port, as
[design-storage.md](design-storage.md) places it: a sub-space the storage domain creates, with a channel to it, its block
requests to the storage domain's block service over the channel and its end at the storage domain's fault gate. Each of
those is a row of this backend ([Spaces, parents and exit records](#spaces-parents-and-exit-records), [Passing a
handle](#passing-a-handle), [Fault gates](#fault-gates)), so the port and `design-storage.md`'s remount rule run unchanged.
A crash injected into littlefs ends only its port, since a fault ends nothing but its space once its gate's server stops
it. What the backend does not promise is that a port which bypasses `liberx` cannot reach the storage domain's memory.

**The system domain's form.** Where the system domain holds the data window itself, as a manifest with no storage domain
has it, littlefs runs in the system domain as a NIF behind the `erx_fs` callback module, the seam the design names, since
the system domain runs no port driver. The Erlang side is the port's, and only the glue below differs.

A process running a dirty NIF cannot run its receive loop, so two share the work. The **owner** takes clients' requests, one at a time, and never
blocks. The **worker**, linked to it, alone calls the littlefs NIF, on a dirty I/O scheduler, one operation at a time.

littlefs reads and programs whole sectors. Its `erase` returns success with no request, since a block device erases nothing. **One block request**,
from a read, program or sync callback:

1. The callback allocates a NIF resource holding a state word, starting *pending*, a result and a buffer. A program copies its bytes into the buffer.
2. It posts `{erx_lfs_block, Op, Sector, Count, Ref}` to the owner with `enif_send`, where `Ref` is the resource term and `Sector` is `(Block * BlockSize + Off)
   / SectorSize`. If `enif_send` reports the owner dead, it fails at once.
3. It waits on the request's condition variable, under its mutex, until the state leaves *pending* or the deadline passes;
   the mutex and condition variable are musl's, over `erx_umtx_wait` and `erx_umtx_wake`.
4. The owner translates `Op` into the [block service's request](design-storage.md#interfaces): `{read, Sector, Count}`; `{write, Sector, Bytes}`, with
   `Bytes = payload(Ref)`, a short NIF returning the buffer as a binary; or `flush`. It sends with a monitor and a reply tag, remembers the one
   outstanding `{Tag, Ref}`, and returns to its receive. The resource stays private to the owner.
5. On the answer it calls `complete(Ref, Result)`, a short NIF that copies any read bytes into the buffer, stores `ok` or `error`, under the mutex moves the state from
   *pending* to *done*, and signals the condition variable.
6. The callback, on *done*, copies a read's bytes into littlefs's buffer and returns 0, or `LFS_ERR_IO` for `error`.

**No dirty-scheduler deadlock.** Steps 4 and 5 and `erx_device` run on normal schedulers, and interrupts arrive by the dispatcher. One operation holds
one dirty thread, and nothing it waits for needs a second. To keep that true, the owner makes no synchronous call; the owner and driver use no file
operation, and no `logger` handler writes to `/data`; `complete` and `payload` are not dirty NIFs.

**Failure has one answer: the volume is unavailable until reboot.** A block error, a deadline (the callback moves the state from *pending* to *ended*,
and a lost swap means the request is done), or the death of the driver or owner leaves the operation's outcome unknown, and it is reported so. The owner
then answers every request `{error, eio}`. The pair's supervisor does not restart it, and nothing replays or remounts. A late `complete` loses its swap and
does nothing; the term keeps the buffer alive. So a delayed old write cannot race a newer one: there are none until the machine has rebooted, and littlefs's
power-loss design handles the reboot. `design-storage.md`'s rule, which remounts once every outstanding request is answered, belongs to the port.

## Deterministic mode

`erx.det=1` is one CPU, TCG with instruction counting, the interpreter. The harness runs QEMU with `-smp 1`, `-icount shift=0,sleep=off` (without `shift`, `-icount` counts nothing), `-rtc base=2026-01-01,clock=vm`, so the real-time clock starts at a fixed date and runs on the instruction count, and the `virt` machine's `dtb-randomness=off`, so the device tree carries no random seeds; `Erx::QemuPlan` adds them exactly when the kernel command line carries `erx.det=1`, and refuses that word under HVF or on more than one CPU. Fiasco's tick comes from
the architecture's generic timer, which instruction counting makes a function of the instructions executed; the time page, deadlines and entropy derive from
that counter and the manifest's seed. ERTS runs one scheduler and the interpreter, in every domain: when the root's boot
information carries `ERX_BOOT_DET`, the domain library starts each domain on the interpreter image, whatever image its
specification names, so no domain gets a JIT space and no code depends on BeamAsm's addresses or hash order. The watchdog's step is off. The comparison starts at erXos's banner, or at the
root's first line if Fiasco's own boot proves not deterministic, recorded as a stopgap difference.

## What Phase 1 code must not assume

* **Handles are opaque**, not Fiasco capabilities and not stable across a boot.
* **A committed page is present here, and Phase 2 populates lazily.** Read no timing or fault counts from it.
* **One node today.** Local message delivery is Phase 1's transport and a frame on a lane is Phase 2's.
* **`erx_device` keeps physical addresses behind the DMA profile**, and nothing else sees one.
* **Faults reach code as crash records**, never as Fiasco's exception messages.
* **Callers check `ERX_ENOTSUP`**, and show `unsupported` and `partial` as such.
* **No thread is destroyed from outside or stopped.** ERTS's use of threads needs neither.
* **A doorbell is a service round trip.** A trigger and an ack queue on the one service thread, so no code may rely on a
  doorbell's latency, and no number measured here decides batching or a native fast path.
* **A program's start costs one service request per object.** Whether a start needs a cheaper path than one kernel call per
  object is decided on erXos's kernel, never from this backend's numbers.
* **No isolation between tasks is promised.** A task that bypasses `liberx` is stopped by nothing here. The hostile
  suites are written against the interface. Here their cases whose verdict is user-mode code's answer to what it reads
  run and count: a funnel's verdict on a malformed or forged frame, a server's on a malformed request, a driver's on a
  malformed descriptor. Their cases that check a bound on memory, CPU or a neighbour's latency, or that a task which
  bypasses `liberx` is held, report `unsupported` here and are claimed only on erXos's kernel.
* **An object can go with the task that created it**, which erXos's kernel does not do. No consumer is affected, since
  [handles flow down](#the-phase-1-backend), but code must not keep an object alive by holding a handle to it in a task
  that is not below its creator.

**A service's request interface is portable.** This is the rule for a service author:

> A service's request interface is the one its design document gives, whatever Phase 1 enforces. A client reaches a service by a pid it was introduced to (the
> facet the domain library hands it at start, or the pid in a reply), never by a registered name of another application, `whereis`, or a module's `start_link`
> return kept across applications. A request and its reply carry portable terms only: atoms, numbers, binaries, lists, tuples, maps, pids and references; never a NIF
> resource, a fun, a port, an ETS table identifier, a `liberx` handle or a Fiasco value. A grant is named by the identifier the server issued for it and nothing else.
> A service reads no table, ETS or `persistent_term`, that another service owns. Local message delivery is Phase 1's transport and a frame on a lane is Phase 2's;
> neither appears in the request's shape. Then moving a service to another domain changes its introduction, not its callers.

The file namespace ([design-files.md](design-files.md)) and the shell's command context ([design-shell.md](design-shell.md)) are the two interfaces to follow first.

## What Phase 1 defers

Every guarantee of `design-kernel.md` (K1 to K33), and every property of `design-domains.md` (D1 to D17),
`design-files.md` (F1 to F9) and the program and shell designs that rests on the kernel. Each row says what runs on
this backend, which is mechanism, and where the guarantee lands. The mechanism is the call table's rows; nothing is
rebuilt in user mode for a guarantee. "M5's kernel part" and "M9's kernel part" are the parts of those milestones that
follow M7 in [plan.md](plan.md). A row whose mechanism a later Phase 1b item adds to this backend names that item,
since no consumer calls it before then.

| Family | On this backend | Guarantee lands |
| --- | --- | --- |
| K1, K2, K17, K21, K24, K25 | handle tables with generations, so a stale handle is `ERX_ESTALE`; handles made only by creation, `erx_cap_dup` and the creator's pass; release at the last handle and mapping; no rights, and no pass sets | Track K's pilot (objects and the capability table, with host tests); conformance tests with Track K's kernel; the hostile tests at M5's kernel part |
| K3, K32 | budgets as records; an object goes with its budget; nothing charged against a guarantee or cap, and no walls, so no domain, the browser-facing web domain included, is held to its own budget | Track K's pilot (budgets); M5's kernel part (walls, "every charge returns"); M10 (users) |
| K4, K5, K6, K9 | the range table; mappings with records, at the rights they were made with, and no protection change over one | Track K (memory, the TLB planner), conformance tests |
| K7, K12, K13 | none | Track K; the hostile suites of M2, M5's kernel part and M11 |
| K8 | no task's mapping writable and executable; code objects only from the root, mapped only once sealed, from 1b-B | 1b-B (code objects); Track K; M7 (the page-table walk); M11 |
| K10, K11, K15, K16 | none | Track K |
| K14, K20, K33 | none | Track K; M2 (the executor rule, `ERX_EWOULDBLOCK`) |
| K18, K27 | a stop ends the tree below a space, children first, and posts each exit record after every thread's deletion has returned; in 1b-A every space is created by the root under its own space, so a tree is one level deep | 1b-B (sub-spaces at a task's request, ended with their parent); Track K (the bounded finishing path, stops under hostile load) |
| K26 | a deleted object's mappings revoked in every task, its handles `ERX_ESTALE` and their entries taken until their holder closes them, so a domain keeps those of a connect or a give that failed, whose values it never learned, for its life | Track K (queued threads woken with `ERX_ESTALE` and `ERX_EDEAD`) |
| K28 | fault and exit records at the gate fixed at creation, with thread `unknown` and an exit record's `space` the space of the task that asked for the stop | Track K (the thread's identity, resume after repair) |
| K29, K30 | vCPU upcalls over Fiasco's interface if [the source check](#open-decisions), made before 1b-D, passes; otherwise none | 1b-D (the row, if the check passes); Track K; Track P's catchable signals at M7 if the check fails |
| K19, K31 | none | Track K; M12 (the lease, the board watchdog) |
| K22, K23 | none | Track Q |
| groups: C0 to C2, quotas, cohorts, charging, park in the kernel, `erx_group_configure` enforced | groups as records with readiness in their home task | M2; M8 (cooperation) |
| umtx in the kernel, across spaces | umtx within a task; nothing shares a umtx word between tasks | Track K |
| IPC gates with messages, `ERX_EDEAD`, labels and deadlines; rendezvous passing | fault gates carrying records only | Track K |
| D1 to D6, D9, D12, D13 | held by the runtimes' and the system domain's own code (the funnel, exports, the sender rule, flow control), and their tests run here, the hostile runtimes' verdicts on frames included; D12's limits are the runtime's own and hold, but the memory they bound is charged to budgets that are records, so its budget assertions report `unsupported` | M5's kernel part: the hostile cases that need isolation between domains, and D12's budgets |
| D7, D17 | a stop deletes every thread without the runtime, and the exit record follows the last deletion, so both hold here for every domain, a dead domain's write position final when its end is reported; what is missing is a bound on how long the stop takes | Track K (the bounded stop, K18); M5's kernel part (the tests under hostile load) |
| D16 | one writer per page and deletion by the system domain alone, by the domain library's code and the creator-only destroy; charging to child budgets recorded, not enforced | M5's kernel part (charging) |
| F1 to F5, F9 | held by the file servers' and handlers' own code: grants by introduction, roots, narrowing, admission, `ro` | M5's kernel part (what a domain that bypasses `liberx` can reach); M11 |
| F6, F7, F8 | F6 by the file servers and the command server; F7, F8 none | Track S's programs (F6's kernel side at M7); Track Q (F7, F8) |
| SH1, P2, command authority, pipe-end ownership, end of stream by holders | held by the handlers', the pipe server's and the session's code; the backend records no rights, so a program's table is a discipline of its session | M7 (the kernel side: rights and pass sets) |
| devices: confined DMA, IOMMU windows, MSI, device-buffer lifetime, the device secret | drivers in their own domains over unconfined virtio-mmio, every device's objects made by the root and passed to its holder, from 1b-E; so a domain that parses hostile bytes beside a device, the network domain's packets or the display domain's draw clients, can reach all memory through it | 1b-E (the drivers' domains); M9's kernel part; M11 (refused unless configured); M12 (the secret) |
| service CPU admission (facets, lanes, grants), inspection and crash-data authority | facets and lanes run; grants are records | M5's kernel part, M8 (admission); M10 and M11 (authority) |
| the host link holding every facet but the system-shell facet | none | M10, M11 |
| entropy in the kernel; the kernel trace ring; deterministic mode at the kernel's level; one route from user mode; every kernel chokepoint; the kernel stack proof | none | Track K |
| the hostile suites and the security closure | written against the interface; their verdict cases run as tests of user-mode code, and their bound and confinement cases and the budget criteria are written at M5's kernel part, for erXos's kernel alone ([What Phase 1 code must not assume](#what-phase-1-code-must-not-assume)) | Track K's first part (the call-level hostile domains); M2, M5's and M9's kernel parts, M11 |
| the startup proof: `erx_root_plan` run by the packer and the kernel, and its charge evidence ([the root startup rule](#the-phase-1-manifest-check) until then) | the root startup rule | Track K's first part, before GK3 |
| the manifest's properties outside Phase 1's scope ([refused records](#the-phase-1-manifest-check)) | the check's other rows | M9, M11 |
| job control of programs: `erx_space_pause`, `_resume` | refused; programs run on under `Ctrl-Z` | Track K's after-the-switch increment |
| thread-handle generations | a creator's handle to the first thread of a space it created names index 0 of that task with no generation of its own, so once the thread is reaped it names no thread and then the index's next one, as an own-task thread handle does | Track K (thread handles in the capability table, `ERX_ESTALE` once reaped) |
| per-budget page accounting, a budget's `used` | the pool keeps one count, which the root's budget reports as a partial `used`; a carved budget's `used` is `unsupported` | Track K's pilot (budgets); M5's kernel part ("every charge returns") |
| pass plans: a pass checked whole before any item moves | items passed in order until the first refusal; the caller undoes the items before it by a budget's destroy | Track K (passing, with its host-explored core) |
| an IRQ object moved to another group; more IRQ objects than the root's `ERX_FIASCO_IRQS_MAX` slots (256) | a bind of a bound object to another group `ERX_ENOTSUP`; a create past the slots `ERX_ENOMEM` | Track K |
| more than one home group in a task | one home group per task; a second `ERX_ENOTSUP` | M2 (groups whose threads run in any space) |
| a group's parent and CPU set in its record; `erx_group_create` from a task | the parent is ignored; `erx_group_configure` takes any group the caller holds and keeps only the root's own group's CPU set, in the root; `_info` takes only the root's own group (`ERX_CAP_SELF` or its first handle); a task's create `ERX_ENOTSUP` | 1b-C, when a session makes a program's group; M2 (grants) |
| creation and passing from a task other than the root: `erx_space_create`, `erx_irq_create`, `erx_cap_pass`, `erx_image_map` | from the root only, where the domain library runs; from another task `ERX_ENOTSUP` | 1b-B (a session's port driver and pipe server); Track K (by capability, without the root) |
| paged objects, sealing, supply, `ERX_MEM_CODE` | `ERX_ENOTSUP` | 1b-B (a session's code and data objects); Track K (pages supplied on demand) |
| device objects given to a holder domain (`erx_dom_device_give`) | none | 1b-E (M9 on the stopgap); M9's kernel part |
| refusal matrices, mutant seeds and exhaustive models of stopgap rows | one QEMU case for each call a row offers, a seeded failure where a case could pass vacuously | Track K's conformance suite and host-explored cores |

**Recorded gaps**, accepted for Phase 1:

* A fault of the root service hangs every client until the watchdog or the harness's deadline ends the run.
* One thread serves the whole machine, so a long body, such as a stop of a large tree or a budget's destroy, delays every other service call, and every doorbell, ack and program start queues on it.
* Nothing bounds what a task makes the service allocate or do: budgets and grants are records, so one task can exhaust the pool or the service thread for all.
* A handle carries no rights. A task may do with a handle whatever its kind allows, except destroying an object it did not create and passing outside the creator's case: a peer can map a side it should only read writable, and the holder of a bell can bind it.
* Every device is unconfined, and its holder's driver reaches any physical address through the device's DMA.
* An object goes with the task that created it, which erXos's kernel does not do.
* A protection change over a mapping is refused, and so is a range call that cuts one; destroying a slice leaves its mappings until their tasks end.
* A group's threads all run in one task; a task holds one home group, and a group at most 64 bound IRQ objects.
* The page index keys a page by its address with a label in the 12 low bits a page's address leaves clear (`liberx/backend/core/vm_table.h`), one label for each task and each memory object, so at most 4,096 tasks and memory objects exist at once, and a creation past that is `ERX_ENOMEM`, whatever the pool holds.
* A faulting thread waits until its space stops, and `erx_thread_start` cannot resume it, so no fault is repaired.
* A group's `parked` and `ready` outside the root are what that task's `liberx` wrote to its status page.
* A test task's fault status is -1.
* A handle to a thread of the caller's own task names its index, and so does a creator's handle to the first thread of a space it created, so once the thread is reaped it names the index's next thread; a handle used after its own close names whatever its entry names then.
* A group's destroy while it has a thread, a second thread created in a space the caller created, a thread created in a group whose home is another task, and a gate bound to a thread of another task are refused.
* A task has at most 128 live threads, and `erx_thread_create` is also `ERX_ENOMEM` while every free record waits for Fiasco's marker write.
* A failed start that did not reach Fiasco's kill path loses that index until the task ends, and so does a start the service refused for a handle whose create is still in flight, since the stub writes the marker first.
* The root's image is mapped read, write and execute from `sigma0`, so a stray write to its code or read-only data does not fault.
* A label naming no live task is counted, and nothing reads the count.
* A budget's destroy sweeps the whole object table once for its spaces, once for its other objects and once per layer of carved budgets, and in each of those layer sweeps scans the table again for every budget below it, so its cost grows with the square of the table and the depth of the budget tree, and the one service thread, which also serves every task's faults, serves nothing else meanwhile.
* `ERX_SPACE_JIT` gates only `ERX_MEM_JIT`: a task without it still makes code, through an object with no flag or through `erx_space_protect`.
* `erx_fiasco_task_join` trusts its caller: its stub waits on the ended semaphore of the task index the service named, so a space deleted by another root thread between the answer and the wait (a join or release of a space above it, or a budget's end) leaves the stub spinning on the empty slot, and an index reused in that window takes another join's up. The launcher joins from one thread.
* An exit or fault record's `space` is the task's index, which no handle a receiver holds names; the label tells a receiver which space a record is for.
* A root's handle of another task's thread carries the task's index and no generation, so one kept past that space's deletion (by a join, a release or the deletion of a space above it) can name a thread of a space that reuses the index.
* No IRQ object is bound to a task's thread, since only the root binds IRQs, so a stop's detach step has no site.
* `erx_image_map` does not check the program's file hash, and every refusal of its segments reads `ERX_ENOMEM`; each space gets its own copy of an image's segments. A fault message's words are not counted, so a task's raw IPC can put stale numbers in its own crash record.
* A slice's destroy revokes its pages from every space, so a second slice over the same entries loses its mappings too; `erx_mem_copy` does not refuse a JIT object, which this backend does not tell from another, and copies overlapping ranges of one object forward; a task's `erx_release_entry` asks the service for each entry, its file checked on the service thread, and slicing checks no file.
* Without vCPU upcalls, a program takes each signal's default action only.
* When the watchdog ends the machine, log lines the console had not taken are lost.
* The crash frame may interleave with a console driver that is writing, a task's frame with the watchdog end's art and frame, and a kernel `WARN` or panic line may interleave at any time.
* Any littlefs block error, deadline or driver restart in the system domain's form makes the volume unavailable until reboot.
* Only the root's parks and wakes are in `erx:trace`, and the trace ring's `thread`, `space` and `target` are reused indices, not object ids.
* `erx_group_configure` keeps the CPU set of the root's own group alone. On any other group its caller holds it checks the handle and that the set is not empty, and keeps nothing of the grant; no group's rate, ceiling or flags is enforced.
* A kernel hang or a stalled watchdog thread is caught only by the harness's deadline.

## Verification

Each increment is a QEMU transcript test under HVF, one and four CPUs, kept in the suite (TCG runs only the production image's deterministic transcript and one boot smoke at one CPU). A case has a seeded failure, a test-only patch that makes it fail, where it could otherwise pass vacuously, which shows the case
ran the code it claims to; `make check-native-seeds` keeps the suites' seeds and the semaphore race's test kernel. Exhaustive models are written for permanent cores only; a row of the call table is tested by a QEMU case for each call it offers, with AddressSanitizer on the host build, and TSan where it adds a lock. Host tests and TSan models run the pure cores. M7's parity gate runs the `erx` backend differentially against this one over the test corpus. Fuller recipes live with
the tests.

| Case | Seeded failure, and what it shows |
| --- | --- |
| **Image and banner.** `tools/erx check-boot-image` and the QEMU gate's `boot_image` suite: the banner image, the two-file form, and the damage cases, each refusing with its reason | a damaged entry that boots fails the case |
| **Boot information.** Host tests of `erx_boot_info_build` and `erx_boot_args_parse` at every limit, with fuzz targets on the page's reader and the command line; the root and the hosted entry fill the page from one manifest and a test compares the two field by field, those the table says differ excepted | a seeded unchecked `args_off` fails the reader's bounds case under AddressSanitizer; a word past the strings limit that does not refuse fails its case; a seeded wrong `pack_flags` in the root fails the comparison |
| **The watchdog from the command line.** A test release boots under `erx.watchdog=1,5,600` with `erx_watchdog` running: its transcript shows the first pet's time, the machine stays up for more than `D` after that pet, then halts cleanly | The same release with its first pet withheld, under `erx.watchdog=1,5,7` and `1,5,14`: each ends the machine with `ERX_CRASH_CAUSE_WATCHDOG` at its own `B`, which shows the numbers came from the command line; a release whose `erx_watchdog` stops after a pet ends the machine with `ERX_CRASH_CAUSE_WATCHDOG` at `D`; a malformed `erx.watchdog=`, and `1,5,2`, whose `B` is under `D` (`watchdog.c:262-264`), refuse the boot, naming the word |
| **Native boot.** The QEMU gate's `native_boot` suite: the root accepts the record through `user_ptr`, checks the archive's last entry, writes one line through `l4_vcon_write`, and shuts down, so QEMU exits by itself | shutdown removed: the deadline fires. `user_ptr` left 0: the root's accept refuses. The archive's sub-type removed: `sigma0` refuses the page fault and the root's line never comes |
| **Debug log.** `tools/erx check-debug-log` and the gate's `debug_log` suite: the probe's calls, good and malformed, on the hosted backend and as the root over the native path to `l4_vcon_write`, compared record by record | `make check-qemu-mutant`: the native call asks for one byte more than a full message, and only the target's transcript differs |
| **Memory.** The QEMU gate's `native_memory` suite, in the root first: commit, write, raise R to RW; decommit and recommit reads zeros; no access and back keeps contents; every protection change keeps contents and its one page; the whole pool committed at once; the pool's count before and after agree | wrong window page: contents differ. Zeroing skipped: old bytes. Protect takes a fresh page: zeros. Pool check removed: a refused protect is not refused |
| **Protection**, in a test task: a page of code runs in RX; a write in RX and a run in RW each give the expected fault | the drop step skipped: Fiasco adds rights, so the write succeeds and its fault is missing |
| A stack through `PROT_NONE` then RW; a refused protect, with the pool short, changes nothing | commit on access change removed: a fault. Plan applied page by page: the first page changed |
| **musl.** The QEMU gate's `native_musl` suite, a C program using the C library's interface as the root: `printf` of floats, TLS from `.tdata` and `.tbss`, 1,000 create-and-join rounds and 1,000 detached exits pinned across CPUs with the pool's count restored, `pthread_cond_broadcast` over 64 waiters for 20 rounds, timed waits on both clocks never early, a contended mutex, `malloc` and `free` under 8 threads with blocks freed by another thread, `realloc` through `mmap` sizes, `mprotect` to a page's own protection under a running thread and over a hole, `pthread_cancel`, a constructor, `mmap` flags it does not offer, and the refusals; `exit` ends the machine after its `atexit` handler and destructor | `FUTEX_REQUEUE` restored: a broadcast stalls. `__unmapself` not releasing: the pool's count stays down. `mprotect` committing first: the thread running on the page faults |
| **Range table.** `test/host/fiasco_vm_test.rb`, host, exhaustive over page states, ranges and calls against a fake memory unit that adds rights as Fiasco does, plus random sequences; each seed is a mutant there | a target with write and execute admitted. Each of the other seeds of this table's memory rows, and a page given back still mapped |
| **Thread start**, the QEMU gate's `native_threads` suite: TLS in the new thread equals the value given | trampoline omits the thread pointer: the case's line reports a failure |
| **Failed start**, a hook built only into the suite's image (`ERX_FIASCO_TEST_HOOKS`) failing each of the three steps: the status returns, `l4_task_cap_valid` is 0 for the thread, its stack canary is untouched, the next create works | the deletion skipped: the capability stays valid |
| **Claim**, `test/host/fiasco_park_test.rb`, a fake kernel writing the marker late, over every order of exit and create | the claim ignores the marker: the fake's write lands on a live thread |
| **Umtx**: a timed wait is never early; host model and TSan, a wake between compare and sleep, a timeout racing a wake | deadline rounded down. Compare outside the lock: a lost wake. Absorb removed: a stale count |
| **Join loop, 10,000 times**, the `native_threads` suite in musl's form, a word the reaper clears: stack and index reused; after each join the handle names no thread, its capabilities gone and a start refused | reaper's steps 1 and 3 swapped: a live capability. Step 3 removed: the case's patience runs out |
| **Detached loop**, the `native_threads` suite: range and index return; the pool's count is steady | range omitted: the count falls |
| `pthread_cond_broadcast` with 64 waiters, one mutex held at a time | the next waiter's barrier left locked: the deadline fires |
| **Park**, `test/host/fiasco_park_test.rb`, exhaustive over two executors, two objects, three events and two timeouts, with each up landing on its own, and TSan over real threads; on QEMU, the `native_threads` suite, a trigger between the empty check and the park, a turn with two executors on two CPUs, and a timeout racing a wake | the epoch comparison removed: a lost wake. An up to a slot not listed: a stale count. The epoch comparison removed on QEMU: the case's park never returns |
| **Group report**, `test/host/group_report_test.rb`, the executor count over a status page, and the report line both backends write (`erx_group_report_line` in `liberx/backend/core/group_report.h`) at zero and the largest counts, in a buffer of exactly its size and in one a byte short | an empty slot counted, or the last slot skipped: a wrong count. No room kept for the NUL: a write past the buffer. A count one digit short: a wrong line |
| **Kernel reports**, the `function_api` set's `object_info` cases: each topic's `reported` bits as [Reporting kernel objects](#reporting-kernel-objects) lists them; a group before and after its first configure; the root's budget's `used` rising by the pages a commit takes and falling by those a decommit returns, with its `reported` bit clear and `erx_info_partial` naming `used` alone and, for the machine, `memory_total` and `memory_free` with `uptime` reported; the budget topic on a carved budget `ERX_ENOTSUP`; `cpus_online` equal to the CPUs the harness starts. On target, a boot of the `check-qemu` production-image matrix at each CPU count types `erl` at the command shell and each of `erx_kernel_records`'s collectors at the Erlang shell, and holds a summary of what is not `{kernel,unsupported}` to the table: `cpus_online` ok at the guest's count, `uptime` ok and above zero, `memory_total`, `memory_free` and `used` each `{{stopgap,liberx_pool},{partial,N}}` with N above zero, the group's `parked` and `ready` ok, and the CPUs and threads listed whole with nothing reported | the pool's count skipped on a commit: `used` does not move. `capacity_mcpu`'s bit set: the case reads a set bit for a field the table lists clear. A failed `l4_scheduler_info`, through a test hook, leaving `cpus_online` set: the case reads a set bit with the value 0. `used`'s bit set: the case reads a set bit for a partial field. The summary's mutants in `test/host/production_image_test.rb`, each one status off, are refused |
| Affinity to each CPU, read back: the `native_threads` suite pins a thread of raised priority to each CPU in turn while a probe counts on every CPU, and only that CPU's probe stops | mask ignored: every CPU but the first shows the wrong probe stopping |
| **A second task**, the QEMU gate's `native_task` suite: a program from the boot image, built through `elf_plan.c`, commits memory and creates a thread through the service, writes code through a JIT object's read-write alias and runs it through the read-execute alias, then rewrites the page on one CPU and runs it on each other CPU in turn, 2,000 times each, with a status of 0. On HVF this also exercises cache maintenance, as coverage, since no omission is sure to show. A write in the read-execute alias and a run in the read-write alias each end the task with a crash frame the suite reads back, and the machine continues. A line IRQ object and a physical object created from the task are each `ERX_ENOTSUP` | RW alias mapped RX: the write faults, and the case's status is not 0. The range table's own seeds, in `fiasco_vm_test.rb`, catch an index that ignores the label. Without the line refusal, the `irq_refused` case's status is 80 |
| **`libc-test` canary**, the QEMU gate's `native_libc_canary` suite: `Erx::LibcTest::CANARY`, about ten programs covering threads and robust mutexes, TLS, stdio and `malloc`, each as a task through the same runner as `tools/erx check-libc-test`; each must pass and no boot may leak the pool. The whole of `libc-test` is `tools/erx check-libc-test`, held to its verdict table ([musl's own tests](#musls-own-tests)) | a test that does not pass, or is not run: `canary_problems` refuses the totals, in `test/host/libc_test_test.rb` |
| **Task exit**: with a thread spinning on each CPU, the first thread stops the task; `l4_task_cap_valid` is 0 for every thread, semaphore, gate and space of the task; the pool's count returns; the root's stop does the same | thread deletion skipped: the capability stays valid. Memory step skipped: the pool is short |
| **Request against exit**, in `native_task`: one thread loops on `erx_vm_commit` while another faults, 1,000 times, and a new task reuses the label; the service's count of dropped requests, `erx_fiasco_test_dropped`, stays 0, and the pool's count returns | no seed of its own: **Task exit**'s thread deletion seed stops the suite at its earlier `service` case, before this one runs |
| **A task's write**, `native_task`'s `write` case: a task writes tab, newline, an escape sequence and every byte value through `erx_fiasco_task_write`, past two splits of `utcb_bytes_max`, and the suite finds exactly those bytes in the serial log, with Fiasco's carriage return ahead of each newline; lengths past the UTCB and an index past the thread table are refused. The `log` case holds `erx_debug_log` to its escape and its refusals. A task's link refuses a section `task.ld` does not name, in `test/host/libc_test_test.rb` | the write sent through `erx_debug_log`: the judge finds no such bytes |
| **Task fault**: the record appears, and the machine continues | the fault ends the machine: the next line is missing |
| **Interrupt**, the `native_irq` suite: a UART receive and a software object wake a parked executor, across CPUs at four; a trigger between the empty check and the park returns at once; `erx_group_take_ready` returns each label once and the oldest first; a timed park ends at its deadline on the time page's clock; ack lets the next character through, which the harness types through a FIFO when the transcript asks. Host: the ready list and flags in the Park row's model, and the page's scale and the wait against exact arithmetic in `test/host/fiasco_time_test.rb` | ack removed: the second character never arrives. Listed flag ignored: the status page's `ready` shows it twice. The interlock removed: the trigger before the park is lost. The dispatcher's trigger removed: a parked executor's deadline fires. The hooked trigger removed: the case's park reaches its deadline |
| **Trace ring**, `test/host/trace_ring_test.rb`: records read back field by field; a cursor of `UINT64_MAX` returns the head and counts nothing; a reader lapped by more than 4,096 records counts exactly those skipped; a record a test hook rewrites between the reader's two `seq` loads is counted overwritten, not kept, and so is one read while its writer is between its field stores; a read of four writes four records and not the slot after them; a cursor past the head, `max` 0 and `max` 513 each `ERX_EINVAL`; a ring whose head a test hook sets to the last index writes it, then nothing, and its reader answers `ERX_ELIMIT`; under TSan, four writers and a reader, each kept record whole, its fields derived from its index; a task's call `ERX_ENOTSUP` | the second `seq` load removed: the hooked record is kept. The head start returning 0: the present cursor is not the head. The skip counted one short: the lapped count differs. The cursor check removed: the past-the-head case copies stale slots. The `max` bound removed: `max` 513 is accepted. A read that ignores `max`: the read of four copies more, past its slot. The terminal check removed: the write past the last index is accepted. The exhausted head's check removed: its read is not `ERX_ELIMIT`. The odd store removed: the record read in the middle of its write is kept. The ring linked into a task in place of the stub: the link lists' test fails |
| **Trace on four CPUs**, the QEMU gate's `native_trace` suite: a test workload spawned at the Erlang shell, a process that waits for a message or 20 ms and loops, traced with `erx:trace(#{select => [Workload], kernel => true})` and sent a message, shows the kernel's row as exactly one `unsupported` line reported by `kernel`, a backend `park` followed by a `wake` of the same slot, and the workload's `in`, not marked `late`, with every `erts` line naming the workload; a test task started and stopped shows `space_start` and `space_end` with the same `target` and the task's status; the suite never sets the wall clock, so the clock offset is constant. The workload is off the console's output path, but with `kernel => true` printing still feeds the backend row: each printed line parks and wakes executors, whose `park` and `wake` records the trace then prints, and the window bounds that loop; only the trace process and the printer are kept out of the trace, by `{erx_untraced, true}` | the park core's `trace` effect removed: no `park` or `wake`. The clock offset added with the wrong sign: the workload's `in` comes out `late` or out of order with the backend's lines. `erx_trace_read` answering `ERX_OK` with no records: the `unsupported` line is missing, which shows the line comes from the call's answer |
| **Watchdog**, the `native_watchdog` suite: pets hold the machine up past `erx.watchdog=1,2,2`; once they stop, a spinning first thread does not keep the machine from ending, with cause and time since the pet in the record | the end skipped: the guest's own line reports it. Pets ignored: the machine ends before the guest's line |
| **A semaphore's wake across CPUs**, `tools/lib/erx/native_semaphore_race.rb` under `make check-native-seeds`, under HVF at 4 CPUs as every seed runs, on a test kernel whose up holds itself between the dequeue and the activation until the waiter is queued again or half a second passes: at least three raced downs each, followed by an IPC wait that lasts its whole length and by a down that times out; too few raced downs fail the case | the bit's wait removed: the IPC wait ends early and the second down reports an up that never came |
| **End path**, on a quiet console, the QEMU gate's `native_crash` suite: a read of a decommitted page, a write to a read-only page, a read from another thread and a trap each give a whole crash frame, held to what the guest said it would touch; a root fault gives the undrained lines; `erx_machine_end` with each `how` | the frame's write removed: `crash_frame.rb` reports none. The drain removed: the last line is missing |
| **Console handoff**: lines before and after the create arrive once, in order; a counter of the service's `l4_vcon_write` calls stays still after the create; a failed map leaves the sink alone. On the host, `dispatch_test.rb`'s handoff, readers and wrap cases count the core's console writes; natively, the console suite logs a tab and an escape sequence after the create and finds them escaped on the line, and a root that stops with the console suspended still shows its parked record | the sink never switched: the counter moves |
| **littlefs**: a file operation under `+SDio 1` with a block read in the callback completes | `complete` made a dirty NIF: the deadline fires |
| littlefs: an injected block error fails that operation as unknown, and the next is `{error, eio}`; the driver killed under load: no later writes reach it, and after a reboot a file synced earlier is there | the error swallowed: success claimed. The owner resends: a later write is counted. Sync skipped: the file is lost |
| **Manifest check**: each kept property with a seeded violation, each refusal with a seeded record | [the table](#the-phase-1-manifest-check) is the pairing |
| **Service decoder**: fuzz target, and a task sending an unknown number, wrong count, bad index and long payload | word-count check removed: the fuzz target reports it |
| **Chokepoint**: a Fiasco header outside the backend | the seeded violation is the case |
| **Production image.** The QEMU gate's `production_image` suite: the platform record's device paths, and each recorded window's base, size and line, against QEMU's device tree, then the image packed through the manifest check boots to its ERTS line with the watchdog's numbers and the exact argument count, a boot with `erx.det=1 erx.arg=WORD` shows the watchdog off and one more argument, a boot with an unknown `erx.` word and a 256 MiB machine each end at the root's refusal, and a boot with a plain `erx.arg` word is answered at the serial console through `erx_pl011`: a sum, a line with a mistake rubbed out, and an output longer than the transmit FIFO, a boot with `erx.group_report=1` reports every executor parked at the shell, and the TCG smoke boot, with one `-serial` and no `erx.hostlink=1`, reaches the command shell with no host link record; `production_image_test.rb` | a wrong device path, compatible or window, in that test, and a recorded base that is not its path's unit address on the host; a console driver that drops input or output: the console transcript stops; a misread `root_memory` or a lost `-append`: the manifest, watchdog and argument lines fail its transcript; a host link record handed without the word: the TCG smoke boot counts eight more arguments, and faults the root task |
| **The manifest's C reader**: `tools/fuzz/manifest_fuzz.c`, each table of an accepted manifest read back to its count and no further | a row out of a table's range would abort it |
| `make check-reproducible`: two builds of the production image, each clearing `build/runtime/native` first and packing into a directory of its own name, byte-identical in archive and bootable file. OTP and musl build at one path both times, so a path of theirs reaching an output does not show | a time, or a path under the two directories, reaching an output fails it |
| **Function-API set** on each backend that carries a case's row, refusals included | a refusal changed in one backend |
| **Mapping between tasks**, the QEMU gate's `native_space` suite, a root and two tasks: the root creates an object, writes a pattern, maps it read-only into one task and read-write into the other; the writer's bytes reach the reader; the root closes its handle and each task releases its range, and the pool's count returns only after the second release; a map over a committed page or a mapping, and a release that cuts a mapping, are `ERX_EINVAL` and change nothing. Host: `fiasco_vm_test.rb` over runs, pages and mappings | the release's decrement of the mapping list removed: the pool stays short. The overlap check removed: the host model maps over a committed page |
| **Revoke**, `native_space`: an object mapped into both tasks is destroyed by its creator; each task's next read gives a fault record at its gate, and the pool's count returns; a destroy from a task that did not create it is `ERX_ERIGHTS` | the revoke step removed: the reader's read succeeds after the destroy |
| **A stale handle**, `function_api`: a handle to a destroyed object is `ERX_ESTALE`, also after its record is reused by a new object | the generation comparison removed: the stale handle reads the new object's size |
| **The tree**, from 1b-B, `native_space`: a task creates a sub-space, maps its own object into it and starts a thread there; the parent stops; the child's exit record, status `ERX_EXIT_PARENT`, comes before the parent's, each after its threads' deletions, and the pool's count returns | children walked after their parent: the child's object is freed while the child still maps it, and the child's spinning counter in that page moves after the parent's record |
| **Passing**, `native_space`: the root passes a copy and a move of handles to one object into a task, which maps the copy after the root has closed its own handle and finds the root's pattern; each item comes back with its value in the task's table, its type and its mask's rights within the type's, less `DESTROY`; a pass of four into a table with room for three passes three and is `ERX_ELIMIT` at the fourth; a pass stops at a gate's handle with `ERX_ENOTSUP`, leaving the item before it passed; a pass from a space not the caller's, into the caller's own, of a space's handle and of more than four items are refused | none: the holder's map fails if a copy does not raise the count |
| **Fault gates**, `native_space`: a task with a gate as fault gate faults; the gate's server receives a fault record of kind `memory` with the space's label, stops the space and receives the exit record with the stop's status; a wait with nothing posted ends at its deadline with `ERX_ETIMEDOUT`. Host: `fiasco_gate_test.rb`, a model of post, wait and timeout over every order, under TSan with real threads | the owed down removed: the model's next wait returns at once with nothing. The record posted before the deletions: the faulting task's other thread's counter moves after the exit record |
| **Doorbells between tasks**, `native_space`: the root binds a software IRQ object into a task's group before the task's first thread runs and triggers it twice; the task's executor takes the label once after it starts; the task triggers an object bound to the root's group and the root's executor wakes; a thread created in a group whose home is another task is `ERX_ENOTSUP`; the task then exits while the root still holds the object, and the object is left unbound; a second bind of a bound object is `ERX_ENOTSUP` | the bind deferred until the home exists dropped: the task's park reaches its deadline. The home check removed: the cross-task thread is created. The detach at task exit removed: the service's test hook that lists bound objects still shows the object bound to the dead task's group |
| **A budget's destroy**, `function_api` and `native_space`: a budget, a budget carved from it, a space, a group, an IRQ object and two memory objects charged to them; one destroy posts the space's exit record, makes every handle `ERX_ESTALE` and returns the pool's count | the walk skips carved budgets: the pool stays short by the second object's pages |
| **Code objects**, from 1b-B, `function_api`: a paged object maps nowhere unsealed (`ERX_EBUSY`), takes a supply, is sealed, refuses a further supply and a writable map (`ERX_ERIGHTS`), and runs the supplied code through an executable map in a task; `ERX_MEM_CODE` from a task is `ERX_ERIGHTS` | the sealed flag not read at the map: the unsealed map succeeds |
| **Copy and slices**, `native_space`: `erx_mem_copy` between two objects, and `ERX_ESTALE` once the source is destroyed; a slice mapped read-only into a task reads the archive's bytes and its write faults | the destroyed check removed: the copy reads freed pages. A slice mapped with write: the write lands in the archive |
| **A task's start, time and release**, `native_space`: a task reads the wall clock the root set before the task was created and again after the root moves it; a task given a slice of a `domains/<name>/` release lists it with `erx_release_entry`, each path without the prefix and each offset from `release_addr` reading the file's bytes, one path longer than `utcb_bytes_max` included, and an index one past the slice is `ERX_ERANGE`; in a task holding a memory handle whose value equals the index of a thread it created and has not started, `erx_thread_start` of the memory handle is refused and the thread stays unstarted | `erx_time_page` in a task returning the root's address: the read faults. Offsets answered from the archive's start: the bytes differ. The stub taking one piece: the long path is cut. The base check removed: the start takes the memory handle for the thread |
| **Devices in domains**, from 1b-E, the production image suite with the harness's net, gpu and input devices: each platform record path, base and line against QEMU's device tree; the display domain's and the network domain's drivers read each transport's magic and device id through objects the domain library gave them, and an interrupt reaches each driver's group | a platform record naming the transport of another device: that driver reads the wrong device id |
| **Bounds of maps, supplies and copies**, `function_api`: `erx_vm_map`, `erx_mem_copy` and, from 1b-B, `erx_mem_supply` each with an offset plus length one page past the object, and with an offset near 2^64 whose sum wraps, are `ERX_ERANGE` and change nothing; a map off a page boundary or of size 0 is `ERX_EINVAL`; a copy into a slice is `ERX_ERIGHTS` | the end check written without checked arithmetic: the wrapping offset maps a page of the pool past the object, which the test finds by reading a pattern another object holds |
| **Generations**, `function_api` with a host hook that sets a record's generation to its last value: the record's next free retires it, the next create takes another record, and the stale handle is `ERX_ESTALE`; a second thread created in a created space is `ERX_ENOTSUP` | the retire step removed: the generation wraps to an earlier value and the stale handle names the new object |
| **A group and its threads**, `native_space`: destroying a group whose home task still has a thread in it is `ERX_ENOTSUP` and the thread runs on; destroying the budget the group is charged to stops its home task, whose exit record arrives, and its stacks and pool pages return | the refusal removed: the service deletes the thread alone, and the pool count stays short by its stack |
| **A payload read once**, a host test of the service's decoder over a public UTCB a second thread rewrites in a loop: `erx_debug_log` and `task_write` with their length changing between reads never copy more than `utcb_bytes_max` and never more than the length the decoder checked | the body reading the length again from the public UTCB: AddressSanitizer reports the overread |
| **A device's holder restarted**, from 1b-E, the production image suite: the network domain is killed and restarted; the new driver gets a new window and line object and the same contiguous memory, resets the device and passes its traffic test | the line's object not deleted at the exit record: the restarted holder's give is refused with `ERX_EBUSY`, since the line already has an object |
| **vCPU upcalls**, if carried, `native_signal`: an upcall interrupts a computing worker, ends a umtx wait with `ERX_EINTR` and a reply wait not at all, and the frame is restored register by register; a delivery between a handler's last check and its resume enters the handler again | the resume ignoring a queued delivery: the second signal is lost |

## Differences from erXos's kernel

The last column of [the call table](#the-call-table) is this list.

### The hosted backend

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
* **No devices.** A well-formed `erx_mem_create_physical` or `erx_mem_create_contiguous` is `ERX_ENOTSUP`, since a device's address here would be made up, and `erx_mem_dma_addr` and `erx_vm_map` are `ERX_EINVAL`, since no handle names such an object. `erx_device:open/1` reports that refusal for a real window. Its `stand_in` window, in a hosted build alone, is plain memory with software objects for lines, which `erx_device:stand_in_fire/2` fires, so `test/integration/runtime_device_test.rb` runs the BIFs and the bindings from Erlang. Both backends refuse a malformed request from one source, `liberx/backend/core/device_check.h`. Entropy is the host's `getentropy`, and an add takes nothing; with `ERX_HOSTED_ENTROPY_FAIL` set every read is `ERX_ENOTSUP`, the failure the native backend gives when it cannot reach its generator service, so `test/integration/runtime_hosted_smoke_test.rb` sees `erx_bytes:entropy/1` raise.
* **No lines.** `ERX_IRQ_LINE` is `ERX_ENOTSUP` hosted, and `ERX_IRQ_MSI` on both. A trigger of an object not bound delivers nothing, and a bind takes any nonzero group, since there is one.
* **An object fires in the caller's thread.** A trigger has listed its object and advanced the epoch by the time it returns, each fire counted, and a bound object rebinds under a new label or unbinds. Natively a trigger reaches the dispatcher later, the kernel keeps two fires not yet received as one, and a second bind, an unbind and a rebind are `ERX_ENOTSUP`; a caller must wait on the epoch, as an executor does. So `irq_ready_once` and `irq_line_refused` run hosted only, and the rest of the IRQ row on both.
* **A reset is exit status 75**, an end `exit(0)`.
* **A fault is the host's**: the process ends with the host's signal, under `lldb` or a sanitizer, and writes no crash record.
* **A runtime links libSystem.** ERTS's threads are libSystem's pthreads with libSystem's TLS, and `erx_utcb_self` is a thread-local block (`hosted/log.c:40`), so it works on any host thread. Only a thread that `erx_thread_create` or `erx_pthread_create_executor` made has a slot; for one that plain `pthread_create` made, `erx_executor_slot` says none and `erx_park` is `ERX_ETYPE`, as for a worker natively.
* **Time.** `erx_clock_ns` is the host's `CLOCK_UPTIME_RAW`, the raw counter that stock OTP also takes on macOS and that the hosted wait's `OS_CLOCK_MACH_ABSOLUTE_TIME` counts in: nanoseconds, stopped during a sleep of the machine, and never below a thread's earlier read, which ERTS's time supervisor checks on every read and stops the runtime over. `CLOCK_MONOTONIC` does not keep that promise on macOS, since it is the wall clock less the boot time. `erx_time_wall_ns` adds one offset that the entry reads from `CLOCK_REALTIME` at its start, as the time page's wall offset does natively, so a later step of the host's clock does not reach ERTS, and wall time runs behind by the length of any sleep of the machine until the next start. `erlang:system_info(os_monotonic_time_source)` and `os_system_time_source` name these two calls as their functions, and report their unit as the resolution, since neither backend says how fine its clock ticks. The zone is UTC whatever the host's `TZ` says. `statistics(runtime)` fails with `notsup`, as on Fiasco, though the host could answer, so nothing comes to depend on it; no start path calls it.
* **The entry maps an archive.** `liberx/backend/hosted/start.c` holds `main(ARCHIVE, ARGS...)`: it `mmap`s the file read-only, closes it, runs `erx_pack_open` and the manifest reader, builds [the boot information page](#boot-information) and calls `erx_runtime_main`. A missing file or a refusal prints its reason and exits with status 1. A file truncated during the run faults, as the host's. `erx.*` words do not exist here: arguments after the archive's path are `init`'s.
* **The archive has a root that never runs.** `erx_pack_open` requires a root image and a manifest (`pack.c:405`, `:505`), and the packer sizes the root as an executable for the target. A hosted release is packed by the same `Pack#build`, with the same manifest and the same entries under `system/`, and a minimal static executable as `system/root`, so hosted iteration needs neither Fiasco's build nor the cross-compiled ERTS. A test compares the two archives' release files, path and hash; the root, the manifest and the notices, which name what each build links, are excepted. `tools/lib/erx/release_files.rb` lists the files: each beam and `.app` under `lib/<application>-<version>/ebin/` with a `compiled` build receipt naming its source in `otp/` or `erlang/apps/`, each `include/*.hrl` header under `lib/<application>-<version>/include/` with a receipt naming the header itself as its source, and `bin/start.boot`, which `systools` on the stock host build writes from a release file and the applications' own `.app` files.
* **No watchdog.** A pet is accepted and does nothing, so a process stopped under `lldb` lives, and `erx_watchdog` runs as natively.
* **The console's driver is `erx_stdio`** ([design-runtime.md](design-runtime.md#the-console-and-standard-io)).
* **Spaces other than the first are host processes**, so the rows between tasks run under the sanitizers: the first
  process holds the tables the root service holds natively and serves the others over a UNIX socket; a memory object is
  a shared memory region each process maps; an IRQ object fires by a message to the target process's dispatcher thread;
  a space's end is its process's, observed by the first process. It carries the rows between tasks that the domain
  library, connections and sessions use, and no device row, since a hosted runtime has no devices. The same function-API set runs against it, and
  the refusals are the native ones. Its design is written, and reviewed as a design, before its code: who walks a tree
  of exits children first, how a pass crosses processes and how a crashed process's objects are released are its to
  settle. Nothing above `liberx` sees which form ran.

### Transport

The function API is the seam. The `erx` backend's stubs trap into the kernel with the registers of `abi/arch/<arch>.txt`; here the same functions run locally or send
[a request](#the-root-service). No call number or register reaches a caller. The two wires differ in how they are made: every kernel
call's trap is generated from the ABI file, while [the service's wire](#the-root-service) has generated layouts under a hand-written
word-count table, since it ends with this backend.

**The public UTCB is not the native one.** `erx_utcb_self` returns the thread's public block, the start of its record, found through the native UTCB's first user word and the
register user mode can read. It has the ABI's `erx_utcb` layout, with `self` holding its own address and `reserved` zero. Fiasco's native UTCB is the backend's alone: its
`free_marker` occupies the offset of the public `reserved`, and each native call overwrites its message registers. So what a caller put in its public block survives any native
call, and no stub takes a snapshot of it.

## Read in source, never run

The gate's `native_musl` suite has run `libl4sys.p.a` linked beside musl, and musl's start, TLS, identifiers, join, detached exit and condition variables on the root, under HVF at 1 and 4 CPUs.

The gate's `boot_image`, `native_boot`, `production_image`, `native_memory`, `debug_log`, `native_threads`, `native_crash` and `native_task` suites have run the load plan, the region reservations, the banner, the descriptor check, `sigma0`'s paging of the root's image, of the
handoff page and of the archive, `user_ptr`, `l4_vcon_write`, power-off and every call of the [Protection](#protection) table that does not fault, under HVF at 1 and 4 CPUs, with `l4sys` (`libl4sys.p.a`, since `libl4sys-direct.a` lacks `l4_utcb_wrap`) and
`libsigma0.a` linked freestanding. They have also run `l4sigma0_map_mem` over the root's image, one gate as the pager, exception handler and request target of the root's threads, with a root thread calling its own task's gate, the 128 KiB area in
`l4_task_add_ku_mem` on the root, semaphore creation, threads on those UTCB slots, and the deletion of a thread and its semaphore when a start fails at each step, so that an unbound thread that never started can be deleted. `native_threads` and `native_watchdog` have run, with each thread on a CPU in turn, service calls and semaphore wakes across
CPUs, timed waits racing wakes, `l4_scheduler_run_thread`'s mask on a thread before its start and while it runs, priority 255 over a spinning thread, the deletion of a running thread's capability from another CPU with the marker cleared afterwards, the same for the first thread, an index and its
native UTCB reused, and deleted semaphores recreated at the same slot. `native_task` has run `l4_factory_create_task` with the 128 KiB `utcb_area`, a gate and semaphores mapped into a task, a gate named at `L4_BASE_PAGER_CAP` as pager and exception handler in the thread's own task, `l4_thread_control_bind` into another task, `l4_task_map` into a task from the window, one page mapped twice with different rights, user-mode cache maintenance through the read-execute alias, and a task's end while its threads run on other CPUs or call the gate.
Everything below was read at the cited lines and has not been executed.

**Run by hand, not kept in a suite**, a root with a helper thread whose pager it was, under TCG and HVF: a write in R, a run in R or RW, a touch of an
uncommitted or no-access page and a write in RX each fault and the same page keeps its contents; `L4_FP_OTHER_SPACES` on a window page removes the
derived mapping and leaves the window's; mapping RX over RW without the drop leaves the write right. The suites that keep these need the service thread.

**The thread package:**

* A fault never answered blocks its thread until deleted: `thread.cpp:582-584`; the fault paths not read.

The gate's `function_api` suite has run `l4sigma0_map_iomem` over QEMU's `fw_cfg` and refused over RAM, the object's `l4_task_map` from the device window, `l4sigma0_map_anypage` of the contiguous pool's superpage, and `fw_cfg`'s DMA writing a run at the address `erx_mem_dma_addr` gives, which shows that the physical address `sigma0` reports is the device's. The `native_irq` suite reaches the UART through the same object, by `erx_device`'s C interface and the generated PL011 table.

The gate's `native_irq` suite has run `l4_icu_bind` on the UART's receive line with no `-serial_esc`, which the kernel leaves free; `l4sigma0_map_iomem` of the kernel UART's own page, which `sigma0` gives; a bound IRQ object's label arriving at an open wait whole, for a device line and a software `l4_irq_trigger` alike; `l4_irq_detach` stopping deliveries, a software object's fire while detached arriving at the next bind, and a detached line opening again at its next bind; the line masked until `l4_irq_unmask`; and a semaphore up from the dispatcher waking an executor on another CPU.

The gate's `production_image` suite has run ERTS's interpreter as the root, `ERX_CLONE_EXECUTOR`'s path through `pthread_create.c` and `clone.c`, `l4_scheduler_info` as a CPU count, the release's files through `erx_prim_file` from the archive, `init`, `kernel_sup`'s children to `erx_console`'s banners, under HVF at 1 and 4 CPUs, with a one-CPU boot and the deterministic transcript under TCG, and a release's pets, kept past the deadlines and then stopped, under both at 1 CPU.

The same suite boots the image twice in deterministic mode to the shell and compares the two serial transcripts byte for byte from erXos's banner to the shell's line, which includes the counter Fiasco's timer reports; Fiasco's own boot, its delay calibration and timer setup included, gives the same bytes each time.

**Later packages:**

* `enif_send` from a dirty NIF's callback, and its report of a dead receiver: `erl_nif.c:883`.
* The size estimates: backend packages 1 to 6, 3,000 to 4,500 lines of C17; the musl port 1,000 to 2,000, of which threads and `malloc` measure 600; NIF glue about 500.

**The rows between tasks**, to be read in source, each for the first package that carries it:

* `l4_rcv_ep_bind_thread` by the root onto a thread of another task, with deliveries reaching that thread's open wait, and the
  root's stores into the task's memory before the bind visible to the thread after the delivery.
* `l4_task_map` into a task of the archive's pages, which `sigma0` mapped into the root read-only, at read-only rights.
* `L4_FP_OTHER_SPACES` over a page of the device window, removing every task's mapping of a register window.
* `l4_semaphore_up` by the service on a semaphore of a thread of another task, which the root holds at its own slot.
* `l4_irq_detach` by the root of an object bound to a thread of another task, and `l4_icu_bind` of a line whose earlier
  IRQ object was deleted, so a restarted device holder gets its line again.
* The size estimate: the rows between tasks, 2,000 to 4,000 lines of C17 across both backends, a guess until the first rows land.

## Open decisions

**The source check of Fiasco's vCPU interface for signals.** The owner's decision is: a source check first; if Fiasco's
interface carries the ABI's `erx_vcpu` layout without leaking Fiasco's, the backend carries `erx_vcpu_control` and
`erx_vcpu_resume` as [vCPU upcalls on Fiasco](#vcpu-upcalls-on-fiasco) says; otherwise programs take default signal actions
only until M7, and catchable signals arrive with erXos's kernel. The check is one package, read in source and never run, and
must answer each question below at cited lines; any answer of no, or any it cannot give, means the row stays `ERX_ENOTSUP`:

1. Does the fork's kernel, as `Fiasco::KERNEL_OPTIONS` builds it, give a plain task `vcpu_control` and `vcpu_resume`, and
   where must the Fiasco state area live, beside the 128 UTCB slots of the task's area?
2. Does a delivery to an armed thread with events enabled that is blocked in `l4_semaphore_down` end the down, so that a umtx
   wait returns `ERX_EINTR` and the upcall follows, or does it queue until the down ends?
3. Does a delivery to an armed thread running on another CPU bring it to an upcall at its next return to user mode?
4. Does a resume with events enabled and a delivery queued enter the upcall again, so no signal is lost between a handler's
   last check and its return (K29), and what does the sticky flag add?
5. With every fault-diverting and user-mode state bit clear, do page faults and exceptions of an armed thread still reach its
   pager and exception handler, the task's gate?
6. Can the backend copy Fiasco's saved state into the ABI's `erx_vcpu` frame and back, so nothing of Fiasco's layout reaches a
   caller?

**Recommendation:** run the check before Track P's first part starts, so its result decides that part's scope, not its
schedule. If the row stays refused, `sigaction` with a handler fails with `EINVAL`, the error POSIX gives for a signal that
cannot be caught, rather than succeeding with a handler that never runs, so no program mistakes the gap for working signals;
`SIG_IGN` and `SIG_DFL` work. That return is [design-programs.md](design-programs.md#signals-in-liberx)'s to state.

littlefs's protocol stays here while the system domain's form has a manifest that uses it, and `design-storage.md`, whose
target text describes the port, states the placement and links to it.
