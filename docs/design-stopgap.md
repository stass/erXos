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
table the service keeps, never Fiasco capability values. Each task has a run of slots in the root, past the root's own: its
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
| dispatcher | the group's task, one per group | turns IRQ deliveries into triggers | console and block drivers, ERTS's wakes |

A task's own threads create its reaper, at backend initialisation, and its dispatchers, at group
creation, through the ordinary calls. The watchdog, like the root service, holds no thread index and
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
   `sigma0` answers a page fault of the root with (`init_mem.cc:73`, `memmap.cc:170-176`):
   `Root_section_rwx` for the root's image, whose segments one range cannot tell apart, and
   `Root_section_ro` for the archive.
4. `erx_boot_handoff_write` writes the `erx_boot_handoff` record of `abi/kernel.txt` (flags, build
   identifier, index hash, the archive's range, and `/chosen/bootargs` cut at the last whole word)
   into the options block for the kernel. That block is mapped into no task, so it also writes the
   record, by `erx_image_load`, into the **handoff page**, a free page from
   `mem_manager->find_free_ram`, reserved as `Region::Root` with `Root_section_ro`; no free page
   refuses the boot, after the copy. The record's pool fields stay zero, with no reader.
5. `init_kip_infos` assigns the page's address to the kernel information page's `user_ptr`
   (`init_kip.cc:30`), which `boot_info_t` carries there.

**The kernel.** Its options are a constant, `Fiasco::KERNEL_OPTIONS` (`fiasco.rb`), built into
`bootstrap`, with neither `-serial_esc` nor `-serial_input`, and it is built without JDB. Its own
changes are `erx_handoff.cpp`: it accepts the record, prints the banner (`development build: trusted
code only`, the build identifier, the index hash) and panics if no bootloader descriptor covers the
archive. The fork's kernel-call route, `erx_probe` and `erx_syscall`, is out of its build
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
6. Makes its own thread table ([Thread creation](#thread-creation)); fills the time page; seeds
   `rng.c`; creates its gate, the service
   thread, stopped, with the `sigma0` gate as pager, and the watchdog with its configuration and start
   event (`watchdog.c:127`).
7. Points its own `_pager` and `_exc_handler` at its gate and runs the service and the watchdog.
   **From here the service alone touches the root's tables.**
8. Creates its reaper, fills the boot information page (`runtime_entry.c`), moves off the image's small
   stack and enters musl's start path, whose `main` (`runtime_main.c`) calls `sys/erxos`'s `erx_runtime_main`.
   ERTS reads the boot information page, so the one `argv` word in musl's start block goes unused.

A failure in steps 1 to 6 prints its reason through `l4_vcon_write` and ends the machine, with no
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
| `budget`, `space`, `group_ctl`, `group_stat`, `time_page`, `release`, `crash_area`, `system_connection` | `ERX_CAP_NULL` and zeros: `erx_vm_*`, `erx_group_status` and `erx_clock_ns` find theirs with no handle, and no Phase 1 caller takes the rest | the same |
| `cpuset`, `capacity_mcpu` | the manifest's system share's `cpuset` within what `l4_scheduler_info` reports; 1,000 for each CPU, since Phase 1 has no grants | the host's online CPUs; the same |
| node name | `system@` and the manifest's `host` | the same |
| `args` | the manifest's `system_args`, then each `erx.arg=WORD` | the manifest's `system_args`, then `-erx console_driver erx_stdio`, then the command line after the archive's path |
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

The release's files are not checked one by one: the root checks the index and the last entry
(`root_open.c`), and the hosted entry's `erx_pack_open` checks the index, so a read stays in bounds
whatever a file holds. erXos's kernel checks each file at its first slice.

### The command line

`/chosen/bootargs` reaches the root through `erx_boot_handoff_view_t`'s `bootargs` and `bootargs_len`.
`erx_boot_args_parse(bytes, length, out)` in `liberx/backend/fiasco/boot_args.c`, a pure function with a
fuzz target, splits it on spaces and reads three kinds of word: `erx.watchdog=P,D,B`, through the
existing `erx_watchdog_parse`; `erx.det=1`; and `erx.arg=WORD`, at most as many as fit the page's
strings. Other words are ignored, as a boot loader's may be there. A malformed `erx.` word, and an `erx.` word of no known kind, refuses the
boot with a fixed reason. Bootstrap cuts the record at the last whole word, so a parser never sees half
a word.

## The Phase 1 manifest check

Two things stop a production image without it: `Admitted.admit` refuses every
manifest for `root_startup` (`manifest.rb`, and `Pack#build` requires the
admitted bytes), and before that `EmptyNative#check` refuses a full boot and
every `domain`, `partial_boot`, `window`, `service`, `facet`, `introduce`,
`image` and `liveness` record. **`SystemOnly`** sits beside `EmptyNative` and
shares its readers: a development manifest, full or partial boot, with the
system domain alone. It accepts the records the system release's services need
and refuses `domain`, `partial_boot`, `introduce` and `image` records with a
diagnostic naming the milestone that brings them; an `image` record and a
`verified_image` window wait for M6's hash tree sizing. QEMU `virt`'s record is
[config/platforms/qemu-virt.json](../config/platforms/qemu-virt.json) and its
manifest
[config/manifest/qemu-virt-development.txt](../config/manifest/qemu-virt-development.txt).
Its scope, against
[design-system.md](design-system.md)'s properties, each kept property with a
seeded violation and each refusal with a seeded record:

| Property | Phase 1 | Whole again at |
| --- | --- | --- |
| 1 one holder per device and unit | kept; every holder is the system domain | |
| 2 facets name servers | kept: every service's server is the system domain, and a facet must name a service of the manifest; a facet that does is then refused, since the reader's grantee is a domain and the system domain has no row; no introductions | M5 |
| 3 PCIe configuration space | QEMU `virt` drives no bridge in Phase 1, so no holder is allowed and no `pci` device is placed | M9 |
| 4 budgets and grants sum | kept for `root_memory`, baseline and shares, `max_domains` 0, which the manifest reader accepts; `root_startup` by the rule below | Track K (`root_startup`), M5 (`max_domains`) |
| 5 names | kept | |
| 6 no JIT in the root | kept; a full boot may use the native root image, since the interpreter image is not yet the root | |
| 7 the sealing secret | `sealing` is `none`, no entry carries `ERX_ENTRY_SEAL`, no TPM | M11 |
| 8 partitions and devices reach holders | the UARTs part kept; the system domain holds the slot and data windows, as M6 places them; no vault partition, no network device | M9 (storage domain), M11 (vault) |
| 9 a release build's confinement | release builds refused; the unconfined block device is allowed, and the packer leaves `ERX_PACK_UNCONFINED_DMA` clear, which nothing reads | M11 |
| 10 boot order, 11 rescue, 12 child domains, 13 headroom | no configured domains, so nothing to check; `domain` records refused | M5 |

**The root startup rule** is a sanity check, not a proof: the root entry's
loadable segments plus `system_baseline` fit `root_memory`, and `root_memory`
fits the platform's RAM less `fiasco_reserve`. `fiasco_reserve` is a number in
the platform record beside `ram_bytes`, the harness's RAM size. `sigma0`'s
resource dump at 512 MiB on a 4-CPU HVF boot of the fork shows 33.8 MiB it does
not offer the root: 32 MiB of kernel memory, the kernel's image, the device
tree's 1 MiB and `sigma0` itself. QEMU `virt`'s `fiasco_reserve` is 64 MiB,
deliberately generous. The rule leaves the archive out: `bootstrap` reserves it
whole and it is never released, so a manifest's `root_memory` must leave it room
below RAM less the reserve; QEMU `virt`'s 384 MiB leaves it 64 MiB. If either is wrong, the pool fails at boot with a
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

| Archive entry | Kind | What it is |
| --- | --- | --- |
| `boot_kernel_path`, `boot_sigma0_path` | file | Fiasco's kernel and `sigma0`, as `bootstrap` loads them |
| `boot_stand_in_root_path` | file | the root as an ELF file, which `bootstrap` loads |
| `system/root` | image | the same program as an image, the header's root entry, which the root startup rule sizes |
| `system_manifest_path`, `system/NOTICES` | file | what `Pack#build` generates |

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

**Device paths.** Each suite run dumps QEMU's own device tree (`-machine virt,dumpdtb`) and
checks each device path and `compatible` of [config/platforms/qemu-virt.json](../config/platforms/qemu-virt.json)
against it. `/pl011@9040000` exists only when QEMU is given a second `-serial`, which the
harness does not give yet: nothing opens the host link before M3.

## The call table

Every consumer kept in Phase 1 has a row, and `ERX_ENOTSUP` answers everything else. This one table
lists calls, refusals and differences. M7's parity review works from its last column: a difference
not listed is a bug in one backend. "Service" and "local" say where the body runs. The hosted
backend gives the same rows and refusals ([The hosted backend](#the-hosted-backend)), and both pass one function-API test set,
`test/guest/function_api`, which seeds Track K's conformance roster.

| erXos call | Phase 1 consumer | Body | Result and refusals | erXos's kernel instead |
| --- | --- | --- | --- | --- |
| `erx_vm_reserve`, `_commit`, `_decommit`, `_release`, `erx_space_protect` | musl `malloc`, ERTS allocators, stacks | service: [Budgets](#budgets-and-the-ownership-of-pages) | correct contents; `ERX_ENOMEM` from the pool, or with no free range, or with a task's runs full, which refuses a new reserve even where it would merge; write and execute together `ERX_EINVAL`; a touch of a decommitted page is a fault | lazy population with committed memory reserved (K6); protection beneath a ceiling (K4), so `_RX` over private memory is `ERX_ERIGHTS`; a refused call keeps the parts before it (K6); `erx_vm_reserve` without `ERX_VM_FIXED` searches below the placement base, where this one takes the lowest free range of its area |
| `erx_mem_create`, `erx_vm_map` | BeamAsm's JIT object in its test task; the time page, a group's areas | service: pool pages recorded as an object; each map is `l4_task_map` from the window, at addresses the caller reserved and has not committed. `ERX_MEM_JIT` only from a task made with `ERX_SPACE_JIT`, else `ERX_ERIGHTS` | any number of mappings, into the object's own task; another `space` `ERX_ENOTSUP`; no free object of the task's 16, or no pages, `ERX_ENOMEM`; `erx_mem_grow`, sealing `ERX_ENOTSUP` | grow and seal work |
| cache maintenance, the code barrier | BeamAsm | local: asmjit's and ERTS's sequences unchanged ([design-arch-aarch64.md](design-arch-aarch64.md)) | correct | none |
| `erx_mem_create_physical` | the device NIF: UART (M3), virtio-mmio block (M6) | service: `l4sigma0_map_iomem` into the root's device window, over the base and size its caller reads from the manifest's device entry; each map is then `l4_task_map` from there, at addresses the caller reserved, as for a shared object; for the console UART also [the handoff](#the-console) | RAM, which `sigma0` keeps, `ERX_ERANGE`; execute `ERX_ERIGHTS`; a full window `ERX_ENOMEM` | within rights |
| `erx_mem_create_contiguous`, `erx_mem_dma_addr` | the device NIF's buffers and rings (M6) | service: first fit from a [contiguous pool](#the-pool), aligned to its size rounded up to a power of two, at most 1 MiB, wholly below the caller's limit, cached, zeroed, and never given back. `dma_addr` is physical address plus offset, since QEMU `virt` as the harness starts it has no IOMMU | no such run `ERX_ENOMEM`; `dma_addr` of another kind of object `ERX_ETYPE`, past the object `ERX_ERANGE`; execute `ERX_ERIGHTS`; unconfined; `erx_dma_map`, windows `ERX_ENOTSUP` | through a DMA window (M9) |
| `erx_irq_create`, `erx_irq_bind`, `erx_irq_ack`, `erx_irq_trigger` | console (M3), block (M6), `{erx_irq, Device, Line}` sinks; ERTS's wakes | service: `l4_factory_create_irq` and, for a line, `l4_icu_bind`; `l4_rcv_ep_bind_thread(irq, dispatcher, record)`; `l4_irq_unmask`; `l4_irq_trigger` | each label once, the line masked until acked; a second bind of an object and `erx_irq_route` `ERX_ENOTSUP`; a target other than the task's group `ERX_EINVAL`; a line's second object `ERX_EBUSY`; a call from a task other than the root `ERX_ENOTSUP`; budget and resource ignored | by capability, without the root; route applied |
| `erx_group_create`, `_configure`, `_info`, `_take_ready` | the adapter's five changes (M3) | local: [Interrupts and readiness](#interrupts-and-readiness). `configure` keeps only the CPU set of the grant in the caller's UTCB, and `info` writes an `erx_group_report` there, with that set as capacity, `usage_known` 0, and the status page's `parked` and `ready` | correct readiness, in the root; everything else `unsupported`; no guarantee, quota or throttling; one group per task, so a second create `ERX_ELIMIT`, and budget and parent ignored | grants enforced, usage reported |
| `erx_park`, `erx_executor_wake`, `erx_yield` | ERTS's schedulers (M3) | local: [The park protocol](#the-park-protocol); `l4_thread_yield` | no lost wake; a worker `ERX_ETYPE` | in the kernel, the executor switched |
| `erx_umtx_wait`, `erx_umtx_wake` | musl's futexes | local: [The umtx table](#the-umtx-table) | correct within a task | across spaces; `ERX_EFAULT`, `ERX_ESTALE`, `ERX_EINTR` |
| `erx_thread_create`, `_start`, `_exit`, `_set_affinity` | `pthread_create`, ERTS's threads, `libc-test` | [Thread creation](#thread-creation), [Deletion](#deletion); affinity is `l4_scheduler_run_thread` | no free index `ERX_ENOMEM`; an empty mask, or one naming no CPU, `ERX_EINVAL`; affinity runs the thread on one CPU of the mask, its own if the mask holds it; `erx_thread_stop`, `_read`, `_write`, `_set_urgency` `ERX_ENOTSUP` | backed and charged at create; those calls work; the thread may run on any CPU of its mask |
| `erx_pthread_create_executor` | ERTS's normal and dirty CPU schedulers, through `ethr_thr_create` | natively musl's `pthread_create` with the executor class, in the row above; hosted a start wrapper ([Making an executor](design-runtime.md#threads-and-synchronisation)) | `pthread_create`'s; no free index or slot `EAGAIN` | the same call |
| `erx_release_entry` | `erx_prim_file.c` | local, on both backends: `erx_pack_entry_at` and `erx_pack_path_at` over the archive `erx_pack_open` accepted, counting from the first path under `system/` | path, size and offset from `release_addr`; an index past the run `ERX_ERANGE` | `erx_object_info(release, ERX_INFO_IMAGE_ENTRY, ...)` |
| `erx_space_create`, `erx_space_stop`, `erx_image_map` | the test-task launcher in the root (`libc-test` M3, BeamAsm M4) | service: `l4_factory_create_task`; segments through `elf_plan.c`, copied through the window, cleaned and invalidated, mapped code read-execute and data read-write; [task exit](#task-exit). `parent`, `fault`, `label` ignored | a "domain" is a task with no budget, grant, lanes, facets or exit record; `erx_space_pause`, `_resume`, `_clear_caps`, `_quiesce`, `_copy` `ERX_ENOTSUP` | parents, fault gates, exit records, quiesce |
| `erx_cap_dup`, `erx_cap_close`, `erx_object_destroy`, `erx_object_info` | Erlang NIF handles, the launcher | service: the handle table; destroy deletes the Fiasco objects, and for memory revokes every mapping first | destroying a started thread, `erx_cap_pass` `ERX_ENOTSUP` | generations, rights, transfer at rendezvous; a thread ends at once |
| `erx_budget_create`, `_resize`, `_watch` | the domain library's root entry (M3), the inspector | service: [Reporting a budget](#reporting-a-budget) | `used` partial, the rest `unsupported`; resize, watch `ERX_ENOTSUP` | exact, all fields |
| the time page, `erx_time_set_wall` | ERTS's time, deadlines | service fills a page mapped read-only into every task: the scale of the architecture's user-readable counter, the wall offset; reading is local | correct layout | none |
| `erx_entropy_read`, `erx_entropy_add` | ERTS's `crypto` seed, the host link | service: `rng.c`, from the counter and the manifest's seed; each reply holds 16 bytes and each request 32, so the stubs loop | `erx: entropy: quality: low, from the counter alone` in the banner; at most 256 bytes a call; `ERX_ENTROPY_CREDIT` `ERX_ENOTSUP`, since no source is trusted | in the kernel |
| `erx_debug_log`, `erx_log_read` | `liberx`, ERTS's crash path, test tasks; the Erlang log reader | service: [The console](#the-console) | correct | in the kernel |
| `erx_watchdog_pet`, the crash record, `erx_machine_end(res, how)` | M3's criteria | pet: a local atomic store in the root, `ERX_ENOTSUP` in a task, and hosted `ERX_OK` with no effect. End: [The end path](#the-end-path) | correct, except a kernel hang or a stalled watchdog | in the kernel (K19, K31) |
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

A pure core that builds for the host and returns plans (`liberx/backend/core/vm_table.c`). It holds two
facts, runs per task and one index for the machine. The **runs** are the task's reserved addresses, sorted and disjoint, in a fixed array; adjacent runs merge, so a range is
wholly reserved exactly when one run covers it. The **page index** is a hash from a committed page's address and its task to its
window address and protection. A page absent from it is uncommitted, and has no protection to remember, since giving it access
commits it. Each entry owns a distinct window page and the index has two slots for each page the window holds, so committing
never finds the index full and needs no pages for it, and every probe ends at an empty slot.

A call computes a whole plan (its range, the state each reserved page in it becomes, and the pages needed), refuses it if the pool
cannot cover it, and only then applies it, so a refused call changes nothing. Applying walks the range's reserved pages in ascending
address order and gives each its steps from one table of state against target ([Protection](#protection)): take and zero a page, unmap,
map, give the page back. A map or an unmap the kernel refuses after that leaves no state worth continuing from, and ends the machine with
the reason. Commit and decommit pass over holes, as the kernel's do; a protect that meets a hole is `ERX_ERANGE`.

* **Commit:** an uncommitted page takes a page, zeroes it, and `l4_task_map(task, L4_BASE_TASK_CAP, l4_fpage(window,
  L4_PAGESHIFT, prot), l4_map_control(addr, 0, 0))`. A committed page is present, and one already committed becomes read-write as [Protection](#protection) says.
* **Decommit:** `l4_task_unmap(task, l4_fpage(addr, L4_PAGESHIFT, L4_FPAGE_RWX), L4_FP_ALL_SPACES)`, unless the page has
  no access and so no mapping, and the page returns to the pool.
* **Release:** decommit what is committed, drop the addresses from the runs. `ERX_VM_FIXED` over reserved addresses does this first.
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

A shared object is a range table of its own over offsets, under a label above every task's, so its pages are ordinary entries of the
page index: each owns its window page, the pool hands them out, and they come back by the release every table has. They are all
committed when it is created, and it lives until its task ends. `erx_vm_map` maps each page with the requested rights, so a
read-write alias and a read-execute alias are two mappings of one window page. The index holds no entry for a mapping, since an entry owns
its page, so the object's pages keep the index's bound, and a range call over mapped addresses sees them as uncommitted: the caller's own bug, a recorded gap. Since a map only adds rights, each map drops all rights at its address first, so no call leaves a task's page writable and executable at once. No task's mapping has write and
execute at once. The pool window itself does, in the root, so M4 checks the range table and tests each JIT alias
by a fault, and the page-table walk belongs to M7.

### Reporting a budget

A budget counts the pages the pool handed out under it. `erx_object_info` reports `used` as **partial**,
reporter `liberx pool`, scope "pages committed through `liberx`; not kernel objects, page tables or mapping
records". `guarantee`, `cap`, `carved`, `lent` and `pinned` are `unsupported`.

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
In the root, a thread's handle is its index, so it carries no generation. Once the thread is reaped the handle names no
thread and is refused, until the index's next create, from which on it names that thread; nothing keeps a handle past a
join, since `pthread_t` is musl's own. On failure the stub frees the
record and returns the service's status. A task names only itself as the space; the root may also name a task with no
thread yet, which takes index 0.

**`erx_thread_start`.** The stub moves the record from created to started, and only then writes the marker 1: a start of any other handle
is refused untouched, since a 1 written over the kernel's 0 would lose the index for good. The service, in order:

1. `l4_thread_control_start`, `_pager` and `_exc_handler` naming the task's gate, `_bind(slot, task)`, `_commit`.
2. `l4_thread_ex_regs(thread, trampoline, record, 0)`. The trampoline's address comes in the start request, as each task's image has its own. A task's first thread starts at the image's entry instead, the one address of the task the root knows: its first instructions put the task's first stack and its C entry in the record and go to the trampoline.
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
status)`, which musl's `exit` does, the launcher's `erx_space_stop(task, status)`, or a fault. In the root it is
`erx_machine_end`.

1. **The threads.** `l4_task_delete_obj` on each thread of the task, newest first, reaper and dispatchers included.
2. **The objects.** Its IRQ objects, semaphores and gate, then the task object, which unmaps everything before the call
   returns (`task.cpp:686-699`).
3. **The memory.** Its pages return to the pool, and its range and handle tables are freed.
4. **The status** goes to whoever started the task, as a test's transcript line: the end ups a semaphore of the root's, on which the launcher's `erx_fiasco_task_join` waits, and that call takes the status and frees the label. A thread that stopped its own task gets
   no reply.

**A request cannot race this.** The service runs each request or fault to completion before it receives the next, finds
the task from the gate's label and each handle in that task's table, and keeps no pointer across a receive. Fiasco IPC
queues no messages: a request is a live thread blocked on the gate, and deleting the thread removes it. So once a stop
returns to the receive, nothing can name that task, and its label is reusable once the status is taken.

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
| `prctl` | answered with no effect for `PR_SET_NAME`, `EINVAL` for any other | `pthread_setname_np` on the caller: a thread's name is kept nowhere |
| `sched_getaffinity` | `erx_fiasco_cpus_online`: the machine's online CPUs in the root, the first CPU in a task | the word `sysconf` counts for `_SC_NPROCESSORS_*`, so ERTS starts a scheduler per CPU |
| `write`, `writev` to 1 and 2, `ioctl` `TIOCGWINSZ` on them | `erx_fiasco_libc_write`: the root's (`libc_root_write.c`, alone in its file so that musl's reference pulls in the console and not the start path) to `erx_fiasco_console_write`, a task's through the service ([The console](#the-console)) | the bytes go out unchanged, as on Unix; other descriptors are `EBADF`; the size reads zero, which keeps stdio line buffered |
| `set_tid_address`, `gettid` | `erx_fiasco_thread_set_clear_word`, the index plus one | |
| `getpid`, `getppid`, the user and group identifiers | 1, 0 and 0 | fixed values: Phase 1 has no processes and no users, so every task reads the same |
| `sched_yield` | `erx_yield` | |
| `set_robust_list`, `rt_sigprocmask`, `tkill` of `SIGCANCEL` | answered with no effect | the signal mask reads empty |

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

## Interrupts and readiness

A group is a backend record in its task: executor slots, status page, park lock, parked list, ready list, listed flags and
dispatcher thread.

* **The dispatcher** blocks in `l4_ipc_wait`. Every message is one IRQ object firing, whose label is the index of its record
  in the group, which the `erx_irq_bind` stub chose. It runs a trigger for that record and waits again, for a device line and
  a software `l4_irq_trigger` alike.
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
through the object's window addresses.

**The loop.** `l4_ipc_wait`; decode; run the body; `l4_ipc_reply_and_wait` with `L4_IPC_SEND_TIMEOUT_0`. A body never calls a stub.

**Refusals.** A label naming no live task is dropped with a counted diagnostic and no reply. An unknown call number, a word count
that differs from the ABI's, a thread index past the table or a payload length past `utcb_bytes_max` is `ERX_EINVAL`; a call without a
row is `ERX_ENOTSUP`. The decoder has a fuzz target. Addresses cross as values, and the service never loads through them.

### Faults, and the fault of the root task

A fault is one more message to the service, which never answers it, because every committed page is already mapped. It names the task,
by the gate, and not the thread, so a crash record's thread field is `unknown`, and it carries the address and instruction pointer.
A page fault is recorded as kind `memory`, with the low three bits of Fiasco's fault word in `cause`, where bit 1 says the access was a
write. Every exception is recorded as kind `undefined`, with the architecture's syndrome in `cause`: the record is for a reader, and
Phase 1 acts on no finer kind.

* **A test task's fault:** the record goes out through `l4_vcon_write`, then [task exit](#task-exit), with a status of -1. The machine continues.
* **The root's fault:** [the end path](#the-end-path).
* **The service's own fault** goes to `sigma0`, which repairs nothing: a recorded gap.

## The watchdog, the crash record and the console

### The watchdog

A root thread at priority 255 runs `watchdog.c`'s step machine: sleep one period, step over the pet word, which holds the time of the last pet.
In deterministic mode the step is off and the machine page says so. A missed pet takes the end path, with `ERX_END_OFF`, as a root fault does.

Its numbers and mode come from [the command line](#the-command-line), with the design's defaults of 1, 5 and 60 seconds. **The pet is the design's
own**: `erx_watchdog`, a process at priority `max` of the release's `kernel`, started among `kernel`'s first children, calling the watchdog NIF from a
normal scheduler each period `P`. Its liveness list is the manifest's `liveness` records, which may be empty, so nothing is special about a release with
no services: the first pet follows the first period. Until then the boot races `B` alone, from the watchdog thread's start, which covers ERTS's start,
`init` and `kernel`'s start up to that process. A hang in any of them ends the machine with a crash record at `B`, as it should.

The root itself never pets on ERTS's behalf: a pet must mean that schedulers run and timers fire. The harness gives QEMU `-append` from one table: TCG
`erx.watchdog=1,30,600`, HVF the defaults, deterministic runs `erx.det=1`. A run's own deadline is at least `B + P + 60` seconds, so a stuck boot ends in the
crash record rather than in the harness's kill: the deadline counts from QEMU's launch and `B` from the later start of the watchdog thread, a missed
`B` is seen at the next tick (`watchdog.c:159-163`), and the record takes time to print. The 60 is a test margin, not a promise about the boot. The time to the first pet has not been measured, since no ERTS has reached it: the first native boot
prints it under both accelerators. A first pet past 60 seconds under HVF is a finding to explain, not a number to raise.

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

**A program's standard output and standard error** deliver its bytes unchanged, whoever holds the program. The root writes them
to the console itself. A task holds no log capability, so `libc_task.c` hands them to `erx_fiasco_task_write`, one `task_write` call
per `utcb_bytes_max`, and the service copies each piece from the caller's public UTCB to `erx_fiasco_console_write`: no record, no
escape and no rate limit, because every task in Phase 1 is a trusted test program. The pieces of a long write are separate calls, so
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
* A failed start that did not reach Fiasco's kill path loses that index until the task ends, and so does a start the service refused for a handle whose create is still in flight, since the stub writes the marker first.
* The root's image is mapped read, write and execute from `sigma0`, so a stray write to its code or read-only data does not fault.
* A label naming no live task is counted, and nothing reads the count.
* A mapping of a shared object has no record, so a range call over one sees uncommitted addresses: `erx_vm_release`, `erx_vm_decommit` and a protect to no access leave it mapped, and a commit or a protect to any access maps a fresh page over it. A second `erx_vm_map` at the same addresses replaces the first. A mapping never outlives its object's pages, since both last until the task ends.
* `ERX_SPACE_JIT` gates only `ERX_MEM_JIT`: a task without it still makes code, through an object with no flag or through `erx_space_protect`.
* `erx_fiasco_task_join` trusts its caller: a task is joined once, and a second join, or a join of an index with no task, waits forever. A space handle is the task's index, so a stale one names the next task to take it.
* `erx_image_map` does not check the program's file hash, and every refusal of its segments reads `ERX_ENOMEM`. A fault message's words are not counted, so a task's raw IPC can put stale numbers in its own crash record.
* `erx_object_destroy` and `erx_cap_close` are not built for memory, so an object lives until its task ends, and no call maps an object into another task.
* A task's fault status is -1, since the ABI file holds no `ERX_EXIT_CRASH` yet.
* Only the root has IRQ objects, so a group in a task has no readiness.
* Eight tasks live at once, and each of a task's range tables is static in the root's image.
* When the watchdog ends the machine, log lines the reader had not taken are lost.
* The crash frame may interleave with a console driver that is writing, and a kernel `WARN` or panic line may interleave at any time.
* Any littlefs block error, deadline or driver restart makes the volume unavailable until reboot.
* A test task's parks and wakes are absent from `erx:trace`.
* `erx_space_create`'s `parent`, `fault` and `label`, and all of `erx_group_configure` but the CPU set, are accepted and ignored.
* A kernel hang or a stalled watchdog thread is caught only by the harness's deadline.

## Verification

Each increment is a QEMU transcript test under TCG and HVF, one and four CPUs, kept in the suite. Each case has a seeded failure, a test-only patch that makes it fail, which shows the case
ran the code it claims to; `make check-native-seeds` keeps the suites' seeds and the semaphore race's test kernel. Host tests and TSan models run the pure cores. M7's parity gate runs the `erx` backend differentially against this one over the test corpus. Fuller recipes live with
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
| Affinity to each CPU, read back: the `native_threads` suite pins a thread of raised priority to each CPU in turn while a probe counts on every CPU, and only that CPU's probe stops | mask ignored: every CPU but the first shows the wrong probe stopping |
| **A second task**, the QEMU gate's `native_task` suite: a program from the boot image, built through `elf_plan.c`, commits memory and creates a thread through the service, writes code through a JIT object's read-write alias and runs it through the read-execute alias, then rewrites the page on one CPU and runs it on each other CPU in turn, 2,000 times each, with a status of 0. On HVF this also exercises cache maintenance, as coverage, since no omission is sure to show. A write in the read-execute alias and a run in the read-write alias each end the task with a crash frame the suite reads back, and the machine continues. Each IRQ call from the task is `ERX_ENOTSUP` | RW alias mapped RX: the write faults, and the case's status is not 0. The range table's own seeds, in `fiasco_vm_test.rb`, catch an index that ignores the label. Without the IRQ refusal, the `irq_refused` case's status is 80 |
| **`libc-test` canary**, the QEMU gate's `native_libc_canary` suite: `Erx::LibcTest::CANARY`, about ten programs covering threads, TLS, stdio and `malloc`, each as a task through the same runner as `tools/erx check-libc-test`; each must pass and no boot may leak the pool. The whole of `libc-test` stays a report, not a verdict | a test that does not pass, or is not run: `canary_problems` refuses the totals, in `test/host/libc_test_test.rb` |
| **Task exit**: with a thread spinning on each CPU, the first thread stops the task; `l4_task_cap_valid` is 0 for every thread, semaphore, gate and space of the task; the pool's count returns; the root's stop does the same | thread deletion skipped: the capability stays valid. Memory step skipped: the pool is short |
| **Request against exit**, in `native_task`: one thread loops on `erx_vm_commit` while another faults, 1,000 times, and a new task reuses the label; the service's count of dropped requests, `erx_fiasco_test_dropped`, stays 0, and the pool's count returns | no seed of its own: **Task exit**'s thread deletion seed stops the suite at its earlier `service` case, before this one runs |
| **A task's write**, `native_task`'s `write` case: a task writes tab, newline, an escape sequence and every byte value through `erx_fiasco_task_write`, past two splits of `utcb_bytes_max`, and the suite finds exactly those bytes in the serial log, with Fiasco's carriage return ahead of each newline; lengths past the UTCB and an index past the thread table are refused. The `log` case holds `erx_debug_log` to its escape and its refusals. A task's link refuses a section `task.ld` does not name, in `test/host/libc_test_test.rb` | the write sent through `erx_debug_log`: the judge finds no such bytes |
| **Task fault**: the record appears, and the machine continues | the fault ends the machine: the next line is missing |
| **Interrupt**, the `native_irq` suite: a UART receive and a software object wake a parked executor, across CPUs at four; a trigger between the empty check and the park returns at once; `erx_group_take_ready` returns each label once and the oldest first; a timed park ends at its deadline on the time page's clock; ack lets the next character through, which the harness types through a FIFO when the transcript asks. Host: the ready list and flags in the Park row's model, and the page's scale and the wait against exact arithmetic in `test/host/fiasco_time_test.rb` | ack removed: the second character never arrives. Listed flag ignored: the status page's `ready` shows it twice. The interlock removed: the trigger before the park is lost. The dispatcher's trigger removed: a parked executor's deadline fires. The hooked trigger removed: the case's park reaches its deadline |
| **Trace ring**: `erx:trace` shows a park, a wake and an IRQ delivery in order; the kernel's row `unsupported` | the dispatcher's write removed |
| **Watchdog**, the `native_watchdog` suite: pets hold the machine up past `erx.watchdog=1,2,2`; once they stop, a spinning first thread does not keep the machine from ending, with cause and time since the pet in the record | the end skipped: the guest's own line reports it. Pets ignored: the machine ends before the guest's line |
| **A semaphore's wake across CPUs**, `tools/lib/erx/native_semaphore_race.rb` under `make check-native-seeds`, under TCG at 4 CPUs as every seed runs, on a test kernel whose up holds itself between the dequeue and the activation until the waiter is queued again or half a second passes: at least three raced downs each, followed by an IPC wait that lasts its whole length and by a down that times out; too few raced downs fail the case | the bit's wait removed: the IPC wait ends early and the second down reports an up that never came |
| **End path**, on a quiet console, the QEMU gate's `native_crash` suite: a read of a decommitted page, a write to a read-only page, a read from another thread and a trap each give a whole crash frame, held to what the guest said it would touch; a root fault gives the undrained lines; `erx_machine_end` with each `how` | the frame's write removed: `crash_frame.rb` reports none. The drain removed: the last line is missing |
| **Console handoff**: lines before and after the create arrive once, in order; a counter of the service's `l4_vcon_write` calls stays still after the create; a failed map leaves the sink alone | the sink never switched: the counter moves |
| **littlefs**: a file operation under `+SDio 1` with a block read in the callback completes | `complete` made a dirty NIF: the deadline fires |
| littlefs: an injected block error fails that operation as unknown, and the next is `{error, eio}`; the driver killed under load: no later writes reach it, and after a reboot a file synced earlier is there | the error swallowed: success claimed. The owner resends: a later write is counted. Sync skipped: the file is lost |
| **Manifest check**: each kept property with a seeded violation, each refusal with a seeded record | [the table](#the-phase-1-manifest-check) is the pairing |
| **Service decoder**: fuzz target, and a task sending an unknown number, wrong count, bad index and long payload | word-count check removed: the fuzz target reports it |
| **Chokepoint**: a Fiasco header outside the backend | the seeded violation is the case |
| **Production image.** The QEMU gate's `production_image` suite: the platform record's device paths against QEMU's device tree, then the image packed through the manifest check boots to its ERTS line with the watchdog's numbers and the exact argument count, a boot with `erx.det=1 erx.arg=WORD` shows the watchdog off and one more argument, a boot with an unknown `erx.` word and a 256 MiB machine each end at the root's refusal; `production_image_test.rb` | a wrong device path or compatible, in that test; a misread `root_memory` or a lost `-append`: the manifest, watchdog and argument lines fail its transcript |
| **The manifest's C reader**: `tools/fuzz/manifest_fuzz.c`, each table of an accepted manifest read back to its count and no further | a row out of a table's range would abort it |
| `make check-reproducible`: two builds of the production image, each clearing `build/runtime/native` first and packing into a directory of its own name, byte-identical in archive and bootable file. OTP and musl build at one path both times, so a path of theirs reaching an output does not show | a time, or a path under the two directories, reaching an output fails it |
| **Function-API set** on both backends, refusals included | a refusal changed in one backend |

## Differences from erXos's kernel

The last column of [the call table](#the-call-table) is this list.

### The hosted backend

`liberx/backend/hosted/` gives the call table's rows in a macOS process, for the sanitizers and `lldb`. `liberx/backend/api.h` declares the function API both backends give, and `liberx/backend/core/` holds what they share: the park core, the range table and the calls both refuse, so the same refusals and the same park protocol come from one source. A space is the process, a thread is a pthread, a memory object's pages are one `mmap`ped area, a umtx wait is `os_sync_wait_on_address`, and an IRQ object fires in the caller's thread, with no dispatcher. `test/guest/function_api` is the one test set: its cases read no backend's identifier, and its harnesses, `hosted.c` and `guest.c`, give it a place to print.

These differ from the native backend, and a caller must not depend on either side:

* **A pthread can be an executor.** `erx_pthread_create_executor` claims a thread record and a slot in the creator, so no free slot is its `EAGAIN`, and a start wrapper's cleanup handler gives both back at a return, a `pthread_exit` or an `erx_thread_exit`. The body natively is musl's.
* **A report of the group.** With `ERX_HOSTED_GROUP_REPORT` set, a thread looks at the status page ten times a second and the console gets a line each time the count of parked executors or of executors changes, so a test outside the process can read an idle sample.
* **The host's page is larger.** Apple Silicon's page is 16 KiB and the ABI's is 4 KiB. A host page's protection is the union of its pages', so a touch that must fault natively may succeed hosted when a neighbour in the same host page allows it, and a stray write to an uncommitted page beside a committed one survives its commit. A call's pages change together when it is whole, and a reserve without `ERX_VM_FIXED` starts on a host page, so unrelated ranges share none. A writable and an executable page that end one call in one host page cannot be represented, and end the process with a diagnostic. A decommitted page's bytes stay readable while a neighbour keeps its host page, and are cleaned before the page is next taken, under a brief write right on the whole host page, during which a neighbour's code cannot run.
* **The pool is a count**, of 8 GiB, which OTP's own suites need part of, over a 64 GiB area. Nothing is touched until written, except the range table's index, which its start clears: 64 MiB.
* **A report of runs.** With `ERX_HOSTED_VM_RUNS` set, the console gets a line each time a call changes the count of the range table's runs or of committed pages: the count, its high mark, the limit and the committed pages. `make check-runtime-hosted` prints it at `1>`.
* **A thread's stack switches at its start.** The pthread starts on its own stack and moves to the one the start record names, and back to end, in `arch/aarch64/switch_stack.S`, and `thread.c` tells the address sanitizer of each move. The thread pointer is a field read through `erx_thread_pointer`, since the host owns the register. The first thread is a worker with no thread pointer, and its `erx_thread_exit_release` releases nothing.
* **Affinity is checked, not applied.** macOS cannot hold a thread to a CPU.
* **The wake order is the host's.** Natively the oldest waiter wakes first; `os_sync_wake_by_address_any` promises no order, so that case stays with the native guest. A wake's count is of the host's wakes, so a waiter that waits again at once on the same word may count twice.
* **No devices.** A well-formed `erx_mem_create_physical` or `erx_mem_create_contiguous` is `ERX_ENOTSUP`, since a device's address here would be made up, and `erx_mem_dma_addr` is `ERX_EINVAL`, since no handle names such an object. Both backends refuse a malformed request from one source, `liberx/backend/core/device_check.h`. Entropy is the host's `getentropy`, and an add takes nothing.
* **No lines.** `ERX_IRQ_LINE` is `ERX_ENOTSUP` hosted, and `ERX_IRQ_MSI` on both. A trigger of an object not bound delivers nothing, and a bind takes any nonzero group, since there is one.
* **An object fires in the caller's thread.** A trigger has listed its object and advanced the epoch by the time it returns, each fire counted, and a bound object rebinds under a new label or unbinds. Natively a trigger reaches the dispatcher later, the kernel keeps two fires not yet received as one, and a second bind is `ERX_ENOTSUP`; a caller must wait on the epoch, as an executor does. So `irq_ready_once` and `irq_line_refused` run hosted only, and the rest of the IRQ row on both.
* **A reset is exit status 75**, an end `exit(0)`.
* **A fault is the host's**: the process ends with the host's signal, under `lldb` or a sanitizer, and writes no crash record.
* **A runtime links libSystem.** ERTS's threads are libSystem's pthreads with libSystem's TLS, and `erx_utcb_self` is a thread-local block (`hosted/log.c:40`), so it works on any host thread. Only a thread that `erx_thread_create` or `erx_pthread_create_executor` made has a slot; for one that plain `pthread_create` made, `erx_executor_slot` says none and `erx_park` is `ERX_ETYPE`, as for a worker natively.
* **Time.** `erx_clock_ns` is the host's `CLOCK_UPTIME_RAW`, the raw counter that stock OTP also takes on macOS and that the hosted wait's `OS_CLOCK_MACH_ABSOLUTE_TIME` counts in: nanoseconds, stopped during a sleep of the machine, and never below a thread's earlier read, which ERTS's time supervisor checks on every read and stops the runtime over. `CLOCK_MONOTONIC` does not keep that promise on macOS, since it is the wall clock less the boot time. `erx_time_wall_ns` adds one offset that the entry reads from `CLOCK_REALTIME` at its start, as the time page's wall offset does natively, so a later step of the host's clock does not reach ERTS, and wall time runs behind by the length of any sleep of the machine until the next start. `erlang:system_info(os_monotonic_time_source)` and `os_system_time_source` name these two calls as their functions, and report their unit as the resolution, since neither backend says how fine its clock ticks. The zone is UTC whatever the host's `TZ` says. `statistics(runtime)` fails with `notsup`, as on Fiasco, though the host could answer, so nothing comes to depend on it; no start path calls it.
* **The entry maps an archive.** `liberx/backend/hosted/start.c` holds `main(ARCHIVE, ARGS...)`: it `mmap`s the file read-only, closes it, runs `erx_pack_open` and the manifest reader, builds [the boot information page](#boot-information) and calls `erx_runtime_main`. A missing file or a refusal prints its reason and exits with status 1. A file truncated during the run faults, as the host's. `erx.*` words do not exist here: arguments after the archive's path are `init`'s.
* **The archive has a root that never runs.** `erx_pack_open` requires a root image and a manifest (`pack.c:405`, `:505`), and the packer sizes the root as an executable for the target. A hosted release is packed by the same `Pack#build`, with the same manifest and the same entries under `system/`, and a minimal static executable as `system/root`, so hosted iteration needs neither Fiasco's build nor the cross-compiled ERTS. A test compares the two archives' release files, path and hash; the root, the manifest and the notices, which name what each build links, are excepted. `tools/lib/erx/release.rb` lists the files: each beam and `.app` under `lib/<application>-<version>/ebin/` with a `compiled` build receipt naming its source in `otp/`, and `bin/start.boot`, which `systools` on the stock host build writes from a release file and the applications' own `.app` files.
* **No watchdog.** A pet is accepted and does nothing, so a process stopped under `lldb` lives, and `erx_watchdog` runs as natively.
* **The console's driver is `erx_stdio`** ([design-runtime.md](design-runtime.md#the-console-and-standard-io)).

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

The gate's `native_musl` suite has run `libl4sys.p.a` linked beside musl, and musl's start, TLS, identifiers, join, detached exit and condition variables on the root, under TCG and HVF at 1 and 4 CPUs.

The gate's `boot_image`, `native_boot`, `production_image`, `native_memory`, `debug_log`, `native_threads`, `native_crash` and `native_task` suites have run the load plan, the region reservations, the banner, the descriptor check, `sigma0`'s paging of the root's image, of the
handoff page and of the archive, `user_ptr`, `l4_vcon_write`, power-off and every call of the [Protection](#protection) table that does not fault, under TCG and HVF at 1 and 4 CPUs, with `l4sys` (`libl4sys.p.a`, since `libl4sys-direct.a` lacks `l4_utcb_wrap`) and
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

The gate's `function_api` suite has run `l4sigma0_map_iomem` over QEMU's `fw_cfg` and refused over RAM, the object's `l4_task_map` from the device window, `l4sigma0_map_anypage` of the contiguous pool's superpage, and `fw_cfg`'s DMA writing a run at the address `erx_mem_dma_addr` gives, which shows that the physical address `sigma0` reports is the device's. The `native_irq` suite reaches the UART through the same object.

The gate's `native_irq` suite has run `l4_icu_bind` on the UART's receive line with no `-serial_esc`, which the kernel leaves free; `l4sigma0_map_iomem` of the kernel UART's own page, which `sigma0` gives; a bound IRQ object's label arriving at an open wait whole, for a device line and a software `l4_irq_trigger` alike; the line masked until `l4_irq_unmask`; and a semaphore up from the dispatcher waking an executor on another CPU.

**The ERTS port:**

* The native interpreter boots as the root to `erl_start`'s first line under TCG and HVF, so nothing after that line has been seen to run natively.
* `ERX_CLONE_EXECUTOR`'s path through `pthread_create.c` and `clone.c`; `l4_scheduler_info` as a CPU count (`scheduler.h:129`); a release's first pet.

**Later packages:**

* `enif_send` from a dirty NIF's callback, and its report of a dead receiver: `erl_nif.c:883`.
* Fiasco's boot is deterministic under instruction counting, with medium confidence: its delay calibration and timer setup are unread.
* The size estimates: backend packages 1 to 6, 3,000 to 4,500 lines of C17; the musl port 1,000 to 2,000, of which threads and `malloc` measure 600; NIF glue about 500.

## Open decisions

None for the owner. littlefs's protocol stays here while Phase 1 lasts, and `design-storage.md`, whose target text describes the port, states the placement and links to it.
