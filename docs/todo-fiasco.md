# TODO: Fiasco

Open work on Fiasco, the release kernel, and `liberx`'s Fiasco backend: 0.2's work, the patches, the boot and the build. The index, with the rules for items, is [TODO.md](../TODO.md):
each item has a `[Severity]` tag and a component pointer, and a closed item is deleted.

## Major initiatives

* [High] 0.2 on Fiasco, `liberx/backend/fiasco`: two pieces of the first part of the design's
  [Verification](design-fiasco.md#handles) note are open: the *A stale handle* case of the function API
  suite, and the test that drives the space-create, image-map and pass wrappers with a stale handle, expecting
  `ERX_ESTALE`, with a wrapper mapping a lookup failure to `ERX_ETYPE` as its seeded fault. The design puts that
  test in `test/host/handles_test.rb`, but the wrappers (`service_task.c`, `erx_fiasco_task_create_body`,
  `erx_fiasco_task_image_map_body`; `object.c`, `erx_fiasco_cap_pass_body`) include Fiasco's headers and build
  only for the target, so it belongs in a guest suite, or the design's note changes.
* [Medium] 0.2 on Fiasco, `tools/lib/erx/manifest.rb`: property 19's clause 9
  ([design-packaging.md](design-packaging.md#the-builds-check)) is not built, so nothing shares out the
  page index's labels, the task table's `ERX_FIASCO_TASK_ROWS` or the threads' share of the root's slot pool
  (`ERX_FIASCO_POOL_PAIRS` less two pairs a row, `liberx/backend/fiasco/root_layout.h`), and one domain can
  run the pool or the task table dry for every other, whose creates then answer `ERX_ENOMEM`. It waits on the
  manifest's limits record, which holds no thread, object or mapping limit (the per-domain thread limits
  item). When it lands, the threads' share needs one source: `root_layout.h` derives the pool from the ABI's
  `fiasco_obj_space_slots`, `fiasco_root_handles` and `fiasco_irqs_max` and from Fiasco's base capabilities
  and `ERX_FIASCO_THREADS_MAX`, which the check cannot read, so either those two become ABI facts too, checked
  against Fiasco's header, and the generator derives the pool's pairs for the backend and the check alike,
  or the check repeats the derivation, which the one-source rule forbids. Seeded fault: the clause leaving
  the pool out, under which a manifest whose thread limits pass the threads' share passes.
* [Medium] 0.2 on Fiasco, `liberx/backend/fiasco/irq.c`: an ack is the holder's own `l4_irq_unmask`, so the
  root no longer sees it, and an ack of a level line that is not bound, or whose bind waits for the group's
  dispatcher, reaches an object with no receiver: Fiasco unmasks the line (`irq.cpp:1172-1177`), its next
  assertion masks it again with nothing pending (`Irq_sender::_hit_level_irq`, `irq.cpp:1013-1035`), and the
  make that follows leaves it masked until an ack the holder will not make before a delivery, so the driver
  hangs silently. A line's holder binds into its own home group, which has a dispatcher, so the case needs a
  line bound into a group without one. The fix by construction: refuse a waiting bind of a line or an MSI
  (`ERX_IRQ_LINE`, `ERX_IRQ_MSI`), and say so in the design's "Interrupts and readiness".
* [Medium] 0.2 on Fiasco, `liberx/backend/fiasco/service_stubs.c`: in the root, `erx_irq_trigger` and
  `erx_irq_ack` with a handle number past the root's window (`ERX_FIASCO_ROOT_HANDLES`) reach the root's own
  slots past it: its service gate and thread, the watchdog's slot, every IRQ object's master capability and
  the tasks' runs, whose semaphores a trigger counts up (`semaphore.cpp:321-322`). Only root code with a stray
  number reaches it, never a domain, whose slots past its window are empty. The stub could refuse a number past
  the caller's own table limit, or the design could state that the root's direct uses are checked only by its
  callers. The direct uses also answer only `ERX_OK` or `ERX_ESTALE`, never `ERX_ETYPE` or `ERX_ERIGHTS`, which
  the call table should say.
* [High] 0.2 on Fiasco, `liberx/backend/fiasco`: a Fiasco factory per domain budget, carved from its parent's
  at the budget's creation with the manifest row's kernel-memory figure, and every object of the domain
  created through it, so a domain that spends its kernel memory fails alone with `ERX_ENOMEM`
  ([design-fiasco.md](design-fiasco.md#memory-and-budgets)). IRQ placement is one more such spend: each
  capability-table page of 128 slots a placement first touches in a task comes from the root's factory, so a
  task duplicating one doorbell up to its `cap_limit` makes Fiasco take up to about 510 pages for it.
* [High] 0.2 on Fiasco, `liberx/backend/fiasco`: budgets are not walls over user pages. `budget.c` records a
  budget's guarantee and cap (`budget.c:37-38`, `:116-117`) but refuses no charge, and the pool takes pages for
  no budget (`vm.c:161-165`'s `vm_take`), so one domain's commits can drain the pool that every domain and the
  root's own tables use. The fix is the design's one invariant per wall, `used + carved <= wall`: each record holds one wall
  for guarantee and cap (an elastic kind `ERX_ENOTSUP`, unequal values `ERX_EINVAL`), counts the pool pages charged
  to it and the walls carved from it, a page taken is charged to the owning object's budget inside the call's
  whole-plan check, and a carve, a resize and a destroy adjust the parent's `carved` in the same request, each
  refused where an invariant would break; the root's budget, which has no record, keeps its own pages and the
  walls carved from it in two counters beside the pool's, under the pool's total; the budget topic reports
  `used` partial with `guarantee`, `cap` and `carved` exact (the topic refuses every handle but `ERX_CAP_SELF`
  and reports only `used`: `service.c`, `ERX_INFO_BUDGET`); and the tests and seeded fault the design lists ([design-fiasco.md](design-fiasco.md), "Memory and
  budgets" and "Reporting a budget"). It blocks the release.
* [High] 0.2 on Fiasco, `liberx/backend/fiasco` and the domain service: each domain's threads within its
  grant's CPU set. The root keeps the set in the domain row `domain_space_create` makes, but starts and moves
  threads with the mask they name; the CPU-ceiling row of [the verification](design-fiasco.md#verification)
  wants the start narrowed to the set, a move naming only CPUs outside it `ERX_EINVAL`, and a domain whose set
  names no online CPU refused at admission with its diagnostic. Only a domain row holds a set: a sub-space's
  row holds 0, so the narrowing reads the set through the row's `domain`, never the task's own row, and the
  root's row should hold every CPU rather than 0; moving `space_band`, `cpuset` and `slice_us`, which
  `service_sched_param` likewise reads through `domain`, into a record only domain rows have would make the
  wrong read unwritable ([design-fiasco.md](design-fiasco.md#bands)).
* [Medium] 0.2 on Fiasco, `liberx/backend/fiasco`: every thread start reads the band table only because each
  `l4_scheduler_run_thread` site (`service.c`, `watchdog_thread.c`) calls `erx_fiasco_band_levels`; a new
  site with its own `l4_sched_param` builds. Make `band.c` the one producer of the scheduling parameters,
  from a band, a slice and a CPU mask, with a chokepoint rule refusing `l4_sched_param(` elsewhere (the CPU narrowing
  above wants the same function) ([design-fiasco.md](design-fiasco.md#bands)).
* [High] 0.2 on Fiasco, `test/guest`: the rest of the band suite of
  [the verification](design-fiasco.md#verification), its sub-space band, app session band and root-only domain
  form rows, each with its seeded failure in a guest. The band row is `native_task`'s `band` case and base
  sharing the `system_domain` suite's load; the pure decisions and their seeds are host tests
  (`test/host/fiasco_band_test.rb`, `test/host/dom_core_test.rb`).
* [Medium] 0.2 on Fiasco, `liberx/backend/fiasco`: whole-space pause and resume by the root, for `fork`'s copy
  and job control: the request answered only once every thread is held, the root never waiting for a thread;
  each thread not already held stopped by `ex_regs` with `Exr_cancel` and `Exr_trigger_exception`, its
  exception reply kept until the resume, `liberx`'s wait and call stubs retrying a cancelled wait or call, and a
  space whose threads do not all arrive within the deadline ended, with no Fiasco patch
  ([design-fiasco.md](design-fiasco.md#threads-bands-and-stops), FD21).
* [High] Fiasco backend, `liberx/backend/fiasco`: DMA spaces behind the IOMMU for each confined device;
  whether QEMU's SMMUv3 works with Fiasco's binding under HVF is unverified
  ([design-fiasco.md](design-fiasco.md#devices)). It does not block 0.2: no device of 0.2 is behind an IOMMU
  (virtio-mmio on QEMU `virt`, no IOMMU on the Pi 4), and the unconfined devices are FD12's published
  downside. It blocks the first release that confines a device.
* [Medium] Fiasco backend, `liberx/backend/fiasco`: vCPU signals are designed and not built; the backend has no
  `erx_vcpu_control` or `erx_vcpu_resume` and no bind of an IRQ object to a thread, so `liberx`'s signals in
  programs have no delivery on Fiasco. Build the call table's row as
  [vCPU upcalls on Fiasco](design-fiasco.md#vcpu-upcalls-on-fiasco) states, for Track P
  ([plan.md](plan.md)).
* [High] 0.2 on Fiasco, the release kernel: `Modules.generic` lists `jdb_object.cpp` only for a kernel built
  with the debugger, so the release kernel's build leaves the GPL-2.0 file out; a boot of that kernel
  checks that `sigma0` ignores its object-naming calls failing
  ([design-fiasco.md](design-fiasco.md#the-releases-fiasco-build)).
* [Medium] 0.2 on Fiasco, `fiasco/kernel`: Fiasco's map refuses a user mapping writable and executable at
  once, with a test whose seeded failure removes the check; an estimate of tens of lines, unverified
  ([design-fiasco.md](design-fiasco.md#the-releases-fiasco-build)).
* [High] 0.2 on Fiasco, `tools/lib/erx/fiasco_config.rb`: the release configuration as an exact allowlist, as
  the development one is (the debugger off; the fixed-priority scheduler, `EXPLICIT_REPLY_CAPS` and `IOMMU`
  kept; `PAGEFAULT_TRAMPOLINE`, `ALIEN`, `IRQ_DIRECT_INJECT`, `UART_CHECKSUM` and every other option without a
  consumer off), and its check, which fails an option off the list and a release build with the debugger on;
  the landing gate boots the release configuration once, a smoke test, and the milestone gate runs the QEMU
  suites on it ([design-fiasco.md](design-fiasco.md#the-releases-fiasco-build)).
* [High] 0.2 on Fiasco, `test/guest`: the system-call fuzz campaign, a test domain invoking every slot of its
  object space with random operations, words and typed items from many threads, checking that the root and a
  neighbour still answer and no outside memory changed; its seeded failure is a removed bound in an IRQ
  object's bind ([design-fiasco.md](design-fiasco.md#verification)).
* [Medium] 0.2 on Fiasco, the system-call fuzz campaign and the assembler: the campaign's baselines, coverage
  and crash triage are taken on the LLVM-built kernel, before the 0.2 release build. Upstream's reason for
  `-no-integrated-as` in Fiasco's `Makeconf` is unknown (unverified), so the integrated assembler's output for
  Fiasco's `.S` files is covered only by the QEMU suites until then.
* [Medium] 0.2 on Fiasco, `fiasco/kernel/ORIGIN.md`: the monthly upstream security watch, a review of
  Kernkonzept's `fiasco` commits since the last one recorded, backporting each fix reachable in erXos's
  configuration ([design-fiasco.md](design-fiasco.md#upstream-security-fixes)).
* [Medium] 0.2 on Fiasco, the release build: a check that fails when any file of the release image's link
  closure (kernel, `bootstrap`, `sigma0`) is recorded with a license that is not permissive, headers
  included, with two seeded failures: a build with `jdb_object.cpp` listed again in `Modules.generic`, and one with the original
  `kobject_rpc.h` restored in place of the clean-room header, made without anyone opening it
  ([design-fiasco.md](design-fiasco.md#the-releases-fiasco-build)).
* [High] 0.2 on Fiasco, `liberx/backend/fiasco` and `abi/manifest.txt`: per-domain thread, object and mapping
  limits in the domain-limits record, carried to the root in `domain_space_create` beside the bands and the
  CPU set it carries ([design-abi.md](design-abi.md#principal-domain-and-limit-records)), so an app's session
  takes them from the app template's `limits session` record as every other limit but its band
  ([design-packaging.md](design-packaging.md)), with no
  table of the root's shared between domains; the machine-wide tables (`irq.c:60`'s `irq_objects`, the page
  index's labels and its slice entries) become shares of each domain's limits, a create or map past a limit
  `ERX_ELIMIT`, so no task can fill the 256 IRQ objects (`irq.c:60,171`) and starve every other domain's doorbells, and the
  domain service admits a domain only when the root's kernel memory and tables have its cost left, a session
  only from what lies outside the configured domains' shares
  ([design-fiasco.md](design-fiasco.md#memory-and-budgets), FD14;
  [design-system.md](design-system.md#the-manifest) lists the fields).
* [High] 0.2 on Fiasco, `tools/lib/erx` manifest check: property 19's clause 9
  ([design-packaging.md](design-packaging.md#the-builds-check)), the root's machine-wide tables and its
  kernel memory holding the configured domains' shares plus `max` times the app template's and every session
  template's share, the configured shares reserved, with its seeded violation: an `apps` row whose `max` times
  the app template's object limit passes the page index's 4,096 labels beside the configured domains'. Its run-time
  half is the domain service's admission of a session from the unreserved part, with a test: apps started to
  `max` and a configured domain then ended restarts; admission that does not reserve the configured shares fails it.
* [High] 0.2, littlefs, `tools/fuzz`: the request fuzz target of the release contract's Requests row
  ([design-stopgap.md](design-stopgap.md#release-contract)), `tools/fuzz/lfs_request_fuzz.c` with its seed
  generator `tools/fuzz/lfs_request_target.rb` beside `lfs_image_target.rb`, driving operation sequences through the
  NIF's argument decoder, under an `enif_*` shim, into littlefs built with `erx_lfs_config`, at
  its full `check-fuzz` budget under AddressSanitizer; seeded failure: `bin.size >= len` deleted from `get_path`
  (`otp/erts/emulator/nifs/erxos/erx_littlefs_nif.c`).
* [High] 0.2, littlefs, the release build's check (`tools/lib/erx/release_files.rb`, `RELEASE_SCRIPTS`): refuse a
  system release that names `erx_storage`, whose `erx_littlefs` loads the NIF, so no release runs littlefs in the
  system domain, with a system release naming it as the seeded failure
  ([design-stopgap.md](design-stopgap.md#release-contract), Placement).
* [High] 0.2, littlefs (`littlefs/lfs.c`): a crafted image whose directory tail points back at itself, off the
  list a mount walks, makes `lfs_dir_find` and `lfs_dir_read` loop forever on a dirty I/O thread, and every caller
  of `/data` waits with it (`erx_lfs` calls have no timeout). Not reproduced. Apply the mount's cycle check
  (`lfs_tortoise_detectcycles`) to both walks, `lfs_dir_read`'s state kept in the open directory since its walk
  spans calls, so the walk fails with `LFS_ERR_CORRUPT`, which the NIF answers `{error, eio}`; add the seed to
  `tools/fuzz/lfs_image_target.rb` and a host test, whose seeded failure leaves the check out of `lfs_dir_find`.
  Blocks 0.2 ([design-stopgap.md](design-stopgap.md#release-contract), Failure).
* [High] 0.2, littlefs, the data service's grants (`erlang/apps/erx_storage/src/erx_lfs_mint.erl`, `erx_lfs.erl`):
  root an app's `data` grant at `apps/NAME/SIGNER/`, with the owner checking each path against its grant's
  root, and the release case (property 19's tenth clause keeps the whole-volume grant out of a release's
  manifest, so a user's session holds only its home): a session of a second user opens a file of the first user's home and gets `enoent`; a
  grant minted at the volume's root fails it ([design-stopgap.md](design-stopgap.md#release-contract),
  Grants). It closes the `data` items under
  Security residuals (`rc.conf`, packages, the log's store) and gives `tree apps` its root.
* [High] 0.2, littlefs, the restart-intensity test: the storage domain ended six times within 600 seconds is restarted
  five times and then stays down, reported by the domain service; the intensity not applied, so the sixth end is
  restarted, fails it ([design-stopgap.md](design-stopgap.md#release-contract), Failure).
* [High] 0.2, littlefs, the Input row of the release contract
  ([design-stopgap.md](design-stopgap.md#release-contract)): the seeded fault of the image fuzz target, a
  bound removed from littlefs's directory-entry read, which the target must report under AddressSanitizer;
  `tools/fuzz/lfs_image_target.rb` and `test/host/gate_baseline_test.rb` carry seeds only.
* [High] 0.2, littlefs, the vault's partition, the Keys row of the release contract
  ([design-stopgap.md](design-stopgap.md#release-contract)): a test that reads the vault's files raw
  from the partition and finds no key in the clear, with a file written unsealed as the seeded failure
  ([design-system.md](design-system.md#the-vault)).
* [Medium] 0.2 on Fiasco, `liberx/backend/fiasco/service_task.c` (`:747-750`): a memory object records its
  `ERX_MEM_JIT` flag at its create, and `erx_mem_copy` refuses a JIT object with `ERX_ETYPE`, as the call table
  says ([design-fiasco.md](design-fiasco.md#the-call-table)).
* [Medium] 0.2 on Fiasco, `liberx/backend/fiasco/service_task.c` (`:515-526`): `erx_image_map` answers
  `ERX_ENOMEM` for any failure of the slice lookup or of a segment's share or load; pass on the slice's and the
  reserve's own statuses ([design-fiasco.md](design-fiasco.md#the-call-table)).
* [Medium] 0.2 on Fiasco, `liberx/backend/fiasco/service.c` (the `ERX_FIASCO_CALL_TIME_SET_WALL` case): the
  setter takes no handle, its dispatch passes the body the request's `wall_ns` alone, and it checks no right,
  so any task sets the wall clock. Make it a call on the time page's handle that checks `WRITE` and answers
  `ERX_ERIGHTS` without it, with the release case "the wall clock"
  ([design-fiasco.md](design-fiasco.md#the-releases-cases), [design-time.md](design-time.md#on-fiasco)).
* [High] 0.2 on Fiasco, `liberx/backend/fiasco` (`vm.c:735`, `irq.c:174`, `watchdog_thread.c:87`, `service.c:198-232`,
  `:728-734`, `service_task.c:302-308`): the design's `charge.c` and its `fiasco-charge` chokepoint do not exist:
  there is no such file and no such rule under `tools/lib/erx/chokepoint_rules`. The Fiasco calls that charge a
  task's quota are spread over five files, and a map Fiasco refuses under a range call ends the machine. Move
  every `l4_task_map`, `l4_factory_create` form and
  `l4_task_add_ku_mem` into `charge.c`, each refusal answered `ERX_ENOMEM` with its call undone, add the
  `fiasco-charge` chokepoint with its seeded violation, and the release case "a map at the factory's end"
  ([design-fiasco.md](design-fiasco.md#the-construction)).
* [Medium] 0.2 on Fiasco, `liberx/backend/fiasco/service.h` (`:90`): paged objects are not offered, so
  `erx_mem_create_paged`, `erx_mem_supply` and `erx_mem_seal` answer `ERX_ENOTSUP` and no destination is ever
  sealed. Offer them as the call table's row says ([design-fiasco.md](design-fiasco.md#the-call-table)).
* [Medium] 0.2 on Fiasco, `liberx/backend/fiasco/service.c` (`service_thread_set_affinity`, `service_sched_param`):
  `erx_thread_set_affinity` and a thread's start pass the caller's mask to Fiasco unnarrowed, and a thread with no
  mask stays on the root service's CPU. Narrow every mask to the domain's CPU set and start a thread with no mask
  on that set, with the release case "CPU ceiling"
  ([design-fiasco.md](design-fiasco.md#threads-bands-and-stops)).
* [High] 0.2 on Fiasco, `liberx/backend/fiasco/entropy.c` (`erx_fiasco_entropy_init`): a boot whose seed is the
  counter alone goes on in every build, a release's included, and the Raspberry Pi 4 reads its RNG200 only when
  `/chosen` holds no seed at all. A release's root refuses such a boot with `erx: entropy: refused: a release does
  not run without a seed` and ends as `ERX_END_OFF` before any domain starts, and the Pi 4 reads its RNG200 as
  [Entropy sources](design-platforms.md#entropy-sources) says, with the release case "release entropy"
  ([design-fiasco.md](design-fiasco.md#the-call-table)).
* [Medium] 0.2 on Fiasco, `liberx/backend/fiasco/service.c` (the `ERX_FIASCO_CALL_MACHINE_END` case): `erx_machine_end`
  answers `ERX_EINVAL` for every `how` but `ERX_END_OFF` and `ERX_END_RESET`, `ERX_END_TRIAL` included, so no trial
  request is made. Refuse `ERX_END_TRIAL` with
  `ERX_ENOTSUP` while the boot value is `unknown` and otherwise make the platform's trial request before the
  reset, with the release case "trial" ([design-fiasco.md](design-fiasco.md#the-end-path)).
* [High] 0.2 on Fiasco, `fiasco/kernel`: FD32's entry patch, the firmware's `SMCCC_ARCH_WORKAROUND_1` and `_3`
  at every entry from user mode and every switch between address spaces. Write it, time the null request on the
  Raspberry Pi 4 with and without it ([todo-performance.md](todo-performance.md)), and carry it only if the
  patched median lies within the unpatched runs' spread; otherwise drop it and publish FD32
  ([design-fiasco.md](design-fiasco.md#the-releases-fiasco-build)).
* [High] 0.2 on Fiasco, the Raspberry Pi 4's hardware watchdog (`liberx/backend/fiasco/watchdog_thread.c`,
  `liberx/backend/fiasco/pm_wdt.c`, `config/platforms/raspi4b.json`): on every boot the root's watchdog thread
  arms the BCM2711's power-management watchdog with a 4 s timeout and reloads it at every step, through a window
  of a platform unit only the root maps, so a hang of Fiasco or of the root resets the board, into the committed
  slot after a trial boot ([design-fiasco.md](design-fiasco.md#the-watchdog)); its registers come from the
  clean-room facts record in `hw/svd/pm_wdt/pm_wdt.svd`. Open, for 0.2:
  (1) the cases on the board's manual checklist, not run on 0.1's published card: a development image whose
  root stops its watchdog thread once it armed the watchdog resets within the timeout and boots again; seeded:
  the arming skipped, so the board stays hung;
  (2) a requested off: the design has no end stop the watchdog, so a requested off on the Pi reboots the board
  about 4 s later, but on 0.1's card `halt` leaves the board halted until its power is cycled. Find what stops
  the watchdog or keeps its reset from taking effect, and make the board and the design agree, with the
  checklist's case that after a requested off the board restarts within about 5 s, or its replacement.
* [Medium] 0.2 on Fiasco, the space topics `handles` and `mappings` (`abi/erx_abi.txt`, `abi/inspection.txt`,
  `liberx/backend/fiasco`): the paths `[domains, Id, capabilities]` and `[domains, Id, mappings]` and those
  below a program, marked `build development`, the backend reporter `liberx_placements`, and the root's
  answers from its placement records with each record's object partial; the LVGL renderer's confinement case
  reads them through `/proc` ([design-fiasco.md](design-fiasco.md#reporting-kernel-objects)).

## Stopgap replacements

* [Medium] Fiasco backend, untested glue paths: `erx_log_lock` has never run under
  contention, since the probe has one thread and no call makes another, and
  nothing exercises the alien and vCPU-user guard in `Thread::arm_esr_entry`.
* [Medium] Fiasco backend, `erx_debug_log` on the target: until the root service
  lands, `liberx/backend/fiasco/log.c` runs the kernel's dispatch core in the
  root task with one static public UTCB, a hand-written copy of the generated
  stub, and `liberx/backend/fiasco/arch/aarch64/generated/trap.c` and `utcb.c`
  have no consumer; the service's request stub replaces them. The probe's
  calls run the same core in process on both backends, so its transcript shows
  the console path, the clock and the cross-compiled core, not a kernel entry.
  The test that a call keeps the caller's registers left with the trap route
  and returns with the `erx` backend's kernel.
* [High] Fiasco backend, `liberx/backend/fiasco`, thread handles, blocks 0.2: the handle the root or a creator holds to a created space's first thread is `erx_backend_thread_handle_other`'s value (`liberx/backend/core/handles.h`), the task in the generation bits above slot bits no entry can have, so a close, dup or pass of it is `ERX_ESTALE`, but it is not the entry of the creator's handle table that design-fiasco.md's "Thread creation" names, so `erx_object_info` and the lookup's type and rights checks do not see it. It carries the task row and no generation, so a creator that keeps it past its child's end names the thread 0 of its next child given the same row (`erx_thread_start`, `erx_thread_set_affinity`), beyond FD2's index reuse within one task; the entry's space record generation removes that. Make it the design's ordinary entry, made by the one create path and checked by the one lookup; that needs own-task handles moved first, since an entry value of generation 0 and an own index are the same number. Own-task thread handles are still the bare index, not `ERX_FIASCO_THREAD_HANDLE_BASE` plus the index that "Thread handles" names, so thread 0's handle equals `ERX_CAP_NULL` and `erx_gate_bind` reaches thread 0 only through `ERX_CAP_SELF_THREAD`, and an `erx_cap_pass` item holding an own thread's handle is read as the handle table's entry of that number, so it may pass a memory object instead of being refused; move them onto the base, above `caps_max`, as the design's reserved values. Tests: a pass of an own-thread handle refused (test/host/handles_test.rb covers a close and duplicate of a first-thread handle in a table of 1000 entries).
* [Low] Fiasco backend, `erx_mem_child`: the child's handle is in its caller's table before the eager copy fills it, so a thread of the same task that closes the parent's handle and makes another object under the same number between the two calls has the child filled from that object. Make the creation and the copy one service request.
* [Medium] Fiasco backend, native boot's seeded failures: `user_ptr` left 0, the
  archive's sub-type removed and shutdown removed were each run by hand and
  failed as [the verification table](design-fiasco.md#verification) says;
  nothing in the tree repeats them, as `check-qemu-mutant` does for the debug
  log, and nothing shows that a write to the archive faults. The same holds
  for the crash frame's write removed. `make check-native-seeds` keeps the threads
  and watchdog suites' seeds.
* [Medium] Fiasco backend, `liberx/backend/fiasco/end.c` and `service.c`: nothing tests that an end on the service drains
  the debug log (`erx_fiasco_log_owned`); a broken owner check would lose the emergency-path lines once the log is
  handed to the console, and no gate would fail. Add a native cell that hands the log to the console, logs a record
  and ends on the service, its judge requiring the record before `erx: end`, with a `check-native-seeds` seed that
  makes the check false. The owner check also rests on the service alone calling `erx_debug_log_read`, `_take`,
  `_hand_to_console` and `_take_back` in a root; only `erx_dispatch` has a chokepoint (`dispatch-one-caller`); add
  one for those with a seed.
* [Low] Fiasco backend, the crash suite's end-path row: `erx_machine_end` runs only with
* [Low] Fiasco backend, the crash suite's end-path row: `erx_machine_end` runs only with
  `ERX_END_OFF`; under `-no-reboot` both ends exit QEMU, so the suite cannot tell
  them apart, and the refusal of a bad `how` has no case.
* [Low] Fiasco backend, `liberx/backend/fiasco/service.c`, `erx_object_info`'s cpu topic: no CPU reports `idle_time`.
  The one-shot kernel's fine-grained CPU time charges a context only when it is switched away from
  (`fiasco/kernel/src/kern/context.cpp:1131-1142`, microseconds), and `l4_scheduler_idle_time` returns the idle
  context's count without bringing it up to date (`Scheduler::op_sched_idle`, `kern/scheduler.cpp:125-133`), so a
  CPU that stays idle reads a count that does not grow, and the count includes the interrupts taken while idle.
  Reporting it needs a Fiasco patch that updates the target CPU's idle context first, by a request to that CPU as
  `sys_thread_stats` does for a thread (`kern/thread_object.cpp:766-796`), added to design-fiasco.md's patch list;
  then set the bit, add `CONFIG_FINE_GRAINED_CPUTIME` to `FiascoConfig::REQUIRED`, and change
  `test/fixtures/object_info_driver.c` and `production_image_test.rb`, which expect a CPU to report nothing.
* [Low] Fiasco backend, Fiasco's `Ipc_gate_obj::unblock_all`, `fiasco/kernel/src/kern/ipc_gate.cpp:142-166`: the gate dequeues
  a blocked sender and activates it afterwards, the race `Semaphore` closes with `Thread_sem_woken`, so a timed send can
  return first and the activation land in what the thread blocks in next. The root's one gate is created bound
  (`service.c:161`), and a sender blocks only on an unbound gate, so nothing in `liberx` reaches it. Other runtimes unchecked.
* [Medium] Fiasco backend, `test/guest/function_api`: `erx_budget_create` and `erx_log_read` have bodies but no
  case. Their consumers, the domain library's root entry and the Erlang log reader, arrive with M3; each gets its
  case then.
* [Low] Fiasco backend, `test/guest/native_task/guest.c`, `request_against_exit`: no seed shows the dropped-request
  count can move, as the thread deletion seed stops the suite at its earlier `service` case.
* [Low] Fiasco backend, `liberx/backend/fiasco`, fault gates: each space's `dropped` counter of records lost after its gate was
  destroyed has no reader until the inspector reads it at SV4.
* [Medium] Fiasco backend, `liberx/backend/fiasco/reply_slots.c`, the service's reply slots: a parked fault is freed
  only when its task stops, and nothing bounds a task's parked faults by its threads, so one task can fill the 64
  slots and every later fault of any domain takes the fallback, Fiasco's `reply capability overwritten!` warning
  on the UART (which the QEMU transcript refuses). A task fills them by calling its own gate with a fault-shaped tag
  and a short receive timeout (Fiasco empties the slot, the record stays), by faulting, reaping and re-creating a
  thread (`service_thread_reap`), or, with no hostility, by holding more than 63 faulted threads. No reply resumes a
  wrong thread; the harm is the console and the shared table. The fix by construction is one pager and exception
  gate per thread, labelled with task and thread index: a thread's new fault or its reap then frees its previous
  slot, parked slots never outnumber live threads, the fault record names its thread, and the pause's FD21 miscount
  closes; it is a design change of "The root service". Cheaper: cap a task's parked faults at its started threads
  and stop a task past it. Also, a receive Fiasco refuses because it cannot allocate the root's reply space reads as
  no message, so the loop retries the same slot for ever at the service's priority until the watchdog ends it.
* [Low] Fiasco backend, `tools/lib/erx/native_semaphore_race.rb`: the race runs under TCG at 4 CPUs only, as every
  seed under `make check-native-seeds` does, and no gate runs it under HVF.
* [Medium] Fiasco backend, `test/fixtures/fiasco_park_driver.c`: the exhaustive model reads the core rather than
  the status mirror, so `parked` not mirrored and a slot epoch mirrored relaxed pass every mode. It has one waker in flight, and judges a lost wake only with
  no event or timeout left, so a stuck absorb with no work passes. A two-waker variant and a check of every
  quiet state passed the core by hand (623,596 and 287,527 states) and should replace them.
* [Low] Fiasco backend, `test/guest/native_threads/guest.c` and `test/guest/function_api/cases.c`,
  `park_timeout_races_wake`: between its racing parks and its quiet ones the helper waits through `settle`,
  a umtx wait on the semaphore the park shares, so an up the race left over returns that wait early and is
  gone before the quiet park looks. The quiet park catches only an up arriving after `settle`; a wait that
  does not block on the semaphore, or a zero-deadline down right after the race, would catch both.
* [Medium] Fiasco backend, lookup error precedence (`liberx/backend/fiasco/service_task.c:330`): the space-create
  wrapper turns every failure of its `parent` and `fault` lookups into `ERX_ETYPE`, so a stale handle answers
  `ERX_ETYPE` where design-fiasco.md's "Reserved values and error precedence" passes the lookup's `ERX_ESTALE`
  through unchanged and keeps `ERX_ETYPE` for a live object of another kind. Return the lookup's status, check the
  other wrappers that take a handle for the same collapse, and test the wrappers with a stale handle, not only
  `handle_find`, with the seeded fault the design names.
* [Low] Fiasco backend, `musl/src/internal/erxos/syscall.c`: `munmap` of part of an object's mapping is `EINVAL` and
  `mprotect` over one `ENOTSUP`, where FreeBSD does both; nothing reaches it until musl maps objects.
* [Low] Fiasco backend, `liberx/backend/fiasco/runtime_entry.c` (`tree_facts`): the root accepts the firmware's tree
* [Medium] Fiasco backend, `liberx/backend/fiasco/service_task.c` (`erx_fiasco_task_mem_dma_body`) and the contiguous
  object of `vm.c`: the object does not record `bus - cpu`, so `erx_mem_dma_addr` gives a device the CPU address
  of its memory, where [design-device-tree.md](design-device-tree.md) ("The `given` record") and
  [design-device-dma.md](design-device-dma.md) ("Device addresses and reach") have it give the bus address.
  Until it does, `erx_boot_dma_absent` (`liberx/backend/core/boot_manifest.c`) refuses a device whose DMA range has
  bus addresses unlike its CPU addresses, with the reason `offset`, and the device gets no DMA memory: the Raspberry
  Pi 4's EMMC2 (unit `sd`, config/platforms/raspi4b.json), whose bus addresses start at 0xc0000000, gets none of
  its 1 MiB and moves blocks by programmed I/O. Record
  the offset in the object the root makes from the tree's range, and drop `offset`.
* [Low] Fiasco backend, `liberx/backend/fiasco/runtime_entry.c` (`tree_facts`): the root accepts the firmware's tree
  and joins its facts to the catalogue's entries once, before any give, but after step 8 of
  [Boot handoff](design-fiasco.md#boot-handoff) rather than in step 4, because the catalogue is the domain
  library's view, which the program's start builds (`library_view`) and the root without a program
  (`root_no_program.c`, which shares `root.c`) never builds. Accepting in step 4 alone would only move a refused
  tree's stop earlier. Build the library's view in step 4, in `root_boot`, and accept the tree there with it.
* [Low] Fiasco backend, `liberx/system/dom_apply.c` (`apply_give_step`): `erx_mem_create_contiguous_in` places a
  device's run only inside its DMA range, and a holder's give whose range does not cover the pool (`ERX_ERANGE`)
  fails, so the holder's domain is refused, where the root's own give (`device_memory` in
  `liberx/backend/fiasco/runtime_entry.c`) gives the device no memory with the reason `outside` and
  [design-device-tree.md](design-device-tree.md) ("The `given` record") has the driver move blocks by
  programmed I/O. It fails safe, and does not happen on a supported board: the pool is the lowest RAM `sigma0`
  has free, inside every range the manifests' trees give. An object the check after creation still refuses
  stays unused for the boot's life, in the root's table or, unnamed by its record, in the holder's.
* [Medium] Fiasco backend, `liberx/system/dom_apply.c` (`apply_memory_inside`) and `dom_args.c` (`args_given_words`): a holder's
  memory refused after it is made (`outside`) prints no line, while `tree_facts` already printed the row's
  range, and a refused `erx_mem_dma_addr` reads as no memory rather than as the backend error the root's own
  give stops on; [design-device-tree.md](design-device-tree.md) ("Concurrency and failure") wants one
  line naming the device and the reason. The holder's record is also assembled beside
  `erx_boot_device_given`, not by one pure function both gives call: move the record decision (facts, the
  memory's device address, the row) into one function in `liberx/backend/core/boot_manifest.c` with host
  tests for `outside`, MAC and COHERENT, and let the library report its refusal through it.
* [Low] Fiasco backend, `liberx/backend/fiasco/vm.c`: a contiguous object's run is never given back, so a driver that
  makes and closes such objects in a loop uses the contiguous pool up for good; each object, not each task, holds its run.
* [Medium] Fiasco backend, `liberx/backend/fiasco/vm.c`: the page index's label map (`vm_label_take`, `vm_label_put`, and
  their use in `erx_fiasco_vm_task_open`, `_close` and `object_fill`) has no test, as `vm.c` builds only for the target and
  no suite makes more than a few tasks. A leaked or doubled label gives two tables one key. A host test should exhaust the
  4,096 labels and see the refusal, check a failed fill and a task's close return every label, and reopen a task index
  after its join; BK2's object records, which take over object labels, are the natural place for it.
* [Low] Fiasco backend, `liberx/backend/fiasco/vm.c`, `erx_fiasco_vm_contiguous_create`: a run taken by `erx_fiasco_contig_take`
  is not given back when `object_fill` then refuses (no label left, or no pool page for the object's runs), so a
  refused create leaves the run held. The pool is sized to the devices' declared total, so a held run leaves that
  device's later give `ERX_ENOMEM` for the rest of the boot. No device learned the run's address, so clearing its
  bits on the failure path is safe.
* [Low] Fiasco backend, `liberx/backend/fiasco/irq.c`: an IRQ object is unbound by a holder allowed in its group (the group's home, its creator or the root: `irq_group_allowed`) and freed with its last handle. Whether a restarted block driver can rebind its line through that is untested.
* [Medium] Fiasco backend, `liberx/backend/fiasco/vm.c`, `liberx/backend/core/vm_table.c`: the range table sees an object's mapping as uncommitted, so
  `erx_space_protect` over mapped registers or a mapped run returns `ERX_OK` and puts a fresh pool page there, and a decommit or release leaves the
  mapping reachable. No caller does either. Nothing tests a task that ends holding a physical or contiguous object. A restarted driver spends a contiguous run each life, since
  none comes back.
* [Low] hosted backend, `liberx/backend/hosted/vm.c`: `erx_mem_create` and `erx_vm_map` have no hosted body, which the call table's row asks for, so
  `test/guest/function_api` holds no shared object's case and its device cases stay native alone.
* [Low] upstream, `otp/lib/stdlib/test/y2k_SUITE.erl`: `tz_next_date/1` returns its argument when local time equals UTC,
  so seven cases fail wherever the time zone is UTC, as erXos's is; stock passes only off UTC.
* [Low] Fiasco backend, `liberx/backend/fiasco/page_pool.c` (`erx_fiasco_contig_take`): a contiguous run is aligned only to a
  page, on the claim that no cache-writeback granule exceeds a page, which rests on "no writeback granule exceeds
  2 KiB" ([design-device-dma.md](design-device-dma.md), "Open decisions" 1), unverified against the Arm
  Architecture Reference Manual's description of the cache type register's `CWG`. Read it and cite it in
  `page_pool.h` and design-fiasco.md's `erx_mem_create_contiguous` row, or align runs to the largest granule.
* [Low] Fiasco backend, `liberx/backend/fiasco/thread.c`: a join can return before the index and executor slot are
  free, since the clear comes before the recycle and the marker later still, so a `pthread_create` right after
  a join on a nearly full table gets a transient `ERX_ENOMEM`. musl's port would report `EAGAIN`. A recorded
  residual of the Fiasco backend, not fixed.
* [Low] Fiasco backend, `liberx/backend/fiasco/service.c`, `service_thread_reap`: only the reaper should send this
  request, and nothing checks the caller; `watchdog_thread.c` and `service.c` also share the convention of fixed
  helper slots in the kernel-given UTCB area, which one small enum could own.
* [Medium] Fiasco backend, `liberx/backend/fiasco/thread.c`, `erx_fiasco_semaphore_down`: the
  wait, which the umtx and park effects share, retries every IPC error, including permanent
  ones such as a deleted semaphore, so such a thread spins in the kernel forever rather
  than reporting it.
* [Low] Fiasco backend, `liberx/backend/fiasco/root.ld`: nothing checks whether an orphan section
  lands past `erx_fiasco_image_end`, which `sigma0`'s map of the root's image would then
  miss.
* [Low] Fiasco backend, `liberx/backend/fiasco/root.c`: a refused `erx.` word ends the boot with a fixed
  reason that names no word, though `erx_boot_args_parse` gives it in `refused`. Printing it needs
  the console's escaping function, as it is text from the boot loader.
* [Low] Fiasco backend, `tools/lib/erx/native_root.rb`: musl's headers are system headers to the root's compile, so a compile record leaves them out and nothing audits them for the root's objects.
* [Medium] Fiasco backend, `liberx/backend/fiasco/root.c`: the root writes no `erx_boot_info` page for a test task, though [Boot handoff](design-fiasco.md#boot-handoff) says it does, and it seeds no `rng.c`.
* [Medium] Fiasco backend, `tools/lib/erx/production_image.rb`: the root's link attributes `libl4sys.p.a`,
  `libsigma0.a` and the boot cores whole, under a license the recipe states, and its dependency
  files leave out Fiasco's and the compiler's headers. The boot cores are stated as BSD-2-Clause
  though the root takes BLAKE3's objects from them (BLAKE3's text is present only through the
  audit and its header). `CoreArchive::Built.objects` maps cores to objects, so per-member records
  are within reach for them; this comes before any distribution.
* [Medium] Fiasco backend, `tools/lib/erx/pack_provenance.rb`: an `assembled` receipt binds its artifact to
  its components only by being written. The image packs `users/bin/.../sigma0` while Fiasco's audit
  reads the unstripped `OBJ-.../sigma0`, so a stale installed `sigma0` would pass. The audit should
  record the installed file and how it derives from the audited one.
* [Medium] Fiasco backend, `liberx/backend/fiasco/root.c`: `root_memory_fits` is a pure decision with no
  boundary test: the 512 and 256 MiB boots do not pin its formula. It belongs in a host-built core.
* [Low] Fiasco backend, `liberx/backend/fiasco/vm.c`: the pool takes all of `sigma0`'s memory and only
  checks it against `root_memory`; nothing keeps the excess for a later budget, and nothing holds a
  domain to its own budget, which is a record (docs/design-fiasco.md, "Budgets and groups as
  records"): a configured row below its domain's use is admitted and runs (a storage row of 19 MiB
  admitted a domain that used 29.8 MiB), and only a measurement such as medium_boot's Footprint shows
  it. Footprint should measure each configured domain of the development manifest as it runs, so a
  row that falls below its use fails a suite. Enforcement is erXos's kernel's (Phase 2).
* [Low] Fiasco backend, `liberx/backend/fiasco/group.c`, `irq.c`: a task's dispatcher index is never cleared, so a task
  that named an ordinary thread its dispatcher and let it exit would have later binds made to whatever thread takes
  the index. The backend's own dispatcher never exits. A waiting bind is made only because `erx_fiasco_group_join`
  and `erx_fiasco_dispatcher_set_body`, the two writers of a row's group and dispatcher, both call
  `erx_fiasco_irq_group_ready`; one setter for both would make that hold by construction.
* [Low] Fiasco backend, `liberx/backend/fiasco/service_task.c`: no test shows that a failed create of the console UART leaves the debug log on the line, and the native console suite counts no `l4_vcon_write` of a log record after the handoff; only the host core test counts console writes. A boot whose first create of the console window fails, and a counter the root prints at its end, would close the "Console handoff" row of `docs/design-fiasco.md`.
* [Medium] Fiasco backend, `liberx/backend/fiasco/service.c` `service_log_read`, `service_log_take`: no test shows that a task's `log_read` or `log_take` is refused with `ERX_ENOTSUP`; that check alone keeps a task from having the service write log bytes at an address of the root. Add the case to `test/guest/native_task/program.c` beside `task_write`'s refusals.
* [Low] Fiasco backend, `liberx/backend/fiasco/end.c`: the watchdog's end skips the debug log's parked records, as the service may be mid-write, so a missed pet after the console handoff loses the records the console had not read. At any end, lines the console has read but its driver has not yet written are lost uncounted, and the end's own drain can interleave with the driver's bytes on the UART.
* [Low] Fiasco backend, `tools/lib/erx/glue_imports.rb` reads what the compiler left
  out of line: a change of inlining can move a symbol such as
  `_ZN13Irq_chip_soft7sw_chipE` on or off the list and fail the build.
* [Medium] Fiasco backend, the debug-log probe's report: `tools/erx check-debug-log`
  compares its own transcript, because the conformance guest's protocol
  needs lines that start with `erx-test:`, and a program's only output here
  is a log record with the kernel's prefix. `debug_log.statuses` stays `pending` in the
  roster until the conformance guest can report.
* [Low] Fiasco backend, the host link's boot word: the host link is opt-in through
  `erx.hostlink=1` (`liberx/backend/fiasco/boot_args.c`,
  `liberx/backend/core/boot_manifest.c`), because the root takes the host
  link's UART from the manifest's device-tree path without looking for it in
  the device tree, and a record for a UART the machine lacks faults the system
  domain at the driver's first read. The word goes once erXos's kernel finds
  the UART in the device tree and the root hands the record only for a UART
  that is there ([design-fiasco.md](design-fiasco.md#the-command-line)).
* [Medium] Fiasco backend, cross-CPU signal delivery ([vCPU upcalls on Fiasco](design-fiasco.md#vcpu-upcalls-on-fiasco)):
  a delivery from another CPU reaches the target's home CPU as a cross-CPU request (`fiasco/kernel/src/kern/irq.cpp:1003-1007`,
  `:942-972`), read in source only; how that request's interrupt brings a thread running in user mode on the remote CPU
  to the upcall was not read. Unverified until `native_signal` runs at 4 CPUs; if it fails, the signal waits for the
  target's next kernel call or resume.
* [Medium] Fiasco backend, `liberx/backend/fiasco` and `liberx/program/`, the event rule of
  [vCPU upcalls on Fiasco](design-fiasco.md#vcpu-upcalls-on-fiasco): a kernel call a program's thread makes
  outside the entry macro and the backend's depth-zero call path runs with events enabled and leaves a signal queued
  until the thread's next return through them, silently. The chokepoint check that keeps the backend's kernel calls
  in a program behind those two paths is not built; build it with the vCPU row, with a seeded direct call it catches.
* [Low] Fiasco backend, signals during musl's own waits: Fiasco ends no semaphore down for an event
  (`fiasco/kernel/src/kern/semaphore.cpp:175-179`, `receiver.cpp:666-667`), so a signal for a thread in a condition
  variable's, a mutex's or `sem_wait`'s wait runs only when the wait ends, and `sem_wait` never fails with `EINTR`.
  erXos's kernel ends the wait with `ERX_EINTR`; nothing to do on Fiasco but record the cases `libc-test` and the
  Open POSIX Test Suite show.
* [Low] Fiasco backend, vCPU arming, not read in source: `ex_regs` on an armed thread and the teardown of an armed thread's
  Fiasco state area in the task's second kernel-user area. Read both before the vCPU row lands, and arm a thread only
  after its start, as the thread-start path of [Signals in liberx](design-programs.md#signals-in-liberx) does.
* [Medium] Fiasco backend, `liberx/backend/fiasco/group.c` (`erx_object_info`, `erx_group_info`) and `service.c`
  (`service_object_info`): the group topic answers only the root's own group, and any other group handle the
  root holds is `ERX_ENOTSUP` (design-fiasco.md, "Reporting kernel objects"), so `[domains, D, group]` of
  another domain, which the inspector asks for through the domain library's handle (`erx_domain_lib:info/2`),
  shows every attribute `unsupported`. erXos's kernel reports any group the caller holds, which closes this;
  nothing to do on Fiasco but keep the gap recorded. On Fiasco, another group's `parked` and `ready`
  would need its home task's status page at one address in every task (in the task area beside the label page,
  `thread.h`) so the service reads it through the task window, as `irq.c` writes labels, which
  `liberx/backend/core/object_info.h`'s rule that a backend's facts never come from a task's memory forbids; and
  a group record keeps no CPU set (`erx_fiasco_group_configure_body`), so another group's `cpuset` stays
  unreported.


## Bugs by subsystem

* [Medium] Kernel lines case, `tools/lib/erx/fiasco.rb` (`Fiasco.new(kernel:)`, `kernel_path`):
  a Fiasco object given a test kernel packs it into any medium built through it, and only
  `MediumKind.test`'s `test_programs` marks a medium as test code, so a development medium built
  with such an object would carry `ERX_TEST_KERNEL_WARN`'s branch unmarked; only the one caller,
  `native_console_ring.rb`, keeps it out today. The kernel belongs in `MediumKind.test` (a
  `test_kernel:` that implies test code), passed to `ProductionImage` as `BootImage.new(kernel:)`
  takes one, so a test kernel is a test medium by construction; the image's kernel receipt and
  build facts then name the test kernel too.
* [Medium] Kernel lines case, `tools/lib/erx/native_console_ring.rb`: the case builds only the
  release test kernel, so the "Kernel lines" row's development cell (the loss line and the
  debugger's first output) and its seed, the close at `Jdb::open_debug_console` removed, have no
  run. A development-kind cell of the same case closes it.
* [Low] Ring console core, `erx_console_ring_write` (`kernel/core/console_ring.c`): once the ring
  is full, the newline that opens each Fiasco warning (`WARNX`) is a line of its own that the core
  counts as lost, and the warning's text is counted again, so the loss line overstates the lines
  lost (a run of 256 warnings, 69 written out, reported 362 lost). A segment that only ends an
  empty line should be neither stored nor counted; the case should then pin N.
* [Low] Fiasco kernel, `Uart::startup` in `fiasco/kernel/src/drivers/uart-libuart.cpp` (`dyn_uart`):
  when the kernel options' `uart.compatible_id` names no driver in the kernel's device table, or
  is empty because `bootstrap` found no console UART, `init_uart_instance` leaves `_uart` null and
  `_uart->startup(reg)` dereferences it: a data abort at address 0 before the kernel banner, with
  no diagnostic. Returning false for a null `_uart`, so the kernel runs without a console, with a
  boot test that hands the kernel an unknown compatible, would fix it.
* [Low] Fiasco bootstrap, `fiasco/kernel/src/kern/arm/64/bootstrap-arm-64.cpp` and
  `kern/arm/bootstrap.cpp`: the AArch64 `bootstrap` must read no relocated word before `relocate()`
  has run. `_start` takes its link address from the absolute symbol `_start_link_addr`, not from its
  GOT slot, and the relocator reaches `_DYNAMIC` PC-relatively through a namespace-scope hidden
  declaration, because clang drops the hidden attribute from a block-scope one in a template and
  loads the address from the GOT. Nothing but the QEMU boot suites guards either: a GOT load brought
  back into `_start` or `Elf::relocate`, or a compiler that addresses `_DYNAMIC` through the GOT
  again, links cleanly and hangs before the kernel banner with no diagnostic. A build check that the
  objects defining `_start` and `relocate` carry no GOT relocation (`R_AARCH64_ADR_GOT_PAGE`,
  `R_AARCH64_LD64_GOT_LO12_NC`) in those functions, with a seeded failure, would catch it at link.
* [Low] Fiasco bootstrap, `Elf::relocate` in `fiasco/kernel/src/kern/arm/bootstrap.cpp`: the relocator
  skips without a word whatever it does not handle. It applies only the first `DT_RELACOUNT` entries
  of `DT_RELA`, so a relocation past them (any non-`RELATIVE` one, which the linker sorts last) is
  never applied; it treats every applied entry as `R_AARCH64_RELATIVE` without reading its type;
  with no `DT_RELACOUNT` it applies nothing; and it ignores `DT_JMPREL` (PLT relocations) and
  `DT_RELR` (`-z pack-relative-relocs`). `bootstrap.arm.ld` checks only the format (REL against
  RELA). Each case links cleanly and boots with unrelocated words. A link check that
  `RELASZ / RELAENT` equals `RELACOUNT` and that `.rela.plt` and `.relr.dyn` are empty, with a
  seeded failure, would close all five.
* [Low] Fiasco bootstrap, `fiasco/kernel/src/kern/arm/64/bootstrap-arm-64.cpp` (and
  `32/bootstrap-arm-32.cpp`): entered with the MMU and data cache on, the bootstrap cleans
  `start_of_loader`..`end_of_loader` from the data cache, but `bootstrap.arm.ld` defines both with
  `ABSOLUTE`, so their GOT words hold link addresses (0x1050 and 0x2ec0 in the QEMU `virt` build)
  that `relocate()` never adjusts, and the clean covers addresses the loader is not at. Whether any
  erXos boot path (QEMU `virt` direct boot, the Pi firmware) enters with the MMU on is unverified.
  Reach both PC-relatively, or add the load offset, once a boot path needs it.
* [Medium] Fiasco backend, the console handoff (`liberx/backend/fiasco/service.c`, `service_log_take`): the log is
  handed to the console at the log service's first take, so the early console stops before the console's driver
  touches the UART only because `kernel_sup` starts `erx_syslog_sup` before `user_sup` starts `erx_console` and
  `erx_syslog`'s first take reaches the service. A take refused before it does (`erx_log_nif`'s `take_nif` when
  `enif_alloc` fails, which `erx_syslog:take/2` notes and goes on from) lets the driver start while the service still
  polls records out to the UART, until a later take succeeds. Make the handoff part of the console's own start, a
  synchronous take `erx_console` requires before its driver opens, so the order holds by construction.
* [Low] Fiasco's own warnings (`fiasco/kernel/src/kern/warn.cpp`, `WARN`): `config/fiasco/kernel.defconfig` sets no warning
  level, so both builds take Kconfig's default `WARN_WARNING`, and a warning goes to the kernel's console by polling whatever the
  debug log's sink is. After the log service's first take such a line can fall inside the console driver's writes, as the
  reply-capability warning below does at each domain fault; `thread-ipc.cpp:260` (a fault whose pager capability is invalid) is
  another, whether it fires in erXos's configuration unverified. Either set `WARN_NONE` in the release kernel's configuration
  or publish the interleaving with the release.
* [Medium] 0.2 on Fiasco, the late interrupt after an unmask: an interrupt raised after its holder unmasks the
  line is handled by the holder's Erlang owner 0.6 to 6 ms later on the Raspberry Pi 4 (the mini UART's level
  line and the SD controller's), longer than the mini UART's 0.7 ms receive FIFO, so pastes into the Pi 4's
  serial console can lose bytes; typing at human speed does not (docs/todo-drivers.md, the mini UART item).
  Neither FD16 nor a timer tick is the cause: a probe stamping Fiasco's interrupt entry, the dispatcher's
  wake and the owner's receipt found the kernel path, entry to dispatcher wake, under 10 us, and the rest
  spent with the owner's ERTS scheduler awake but not running, waiting behind the other ERTS threads that
  share CPU 0 at the same Fiasco priority (history repository commits 924e652 and de6a618,
  `pi4/2026-11-22-irq-probe/`, images A to C). With ERTS's busy-wait spinning off (image E, commit 66b1a9e)
  the SD line's receipts all fall under 615 us, but the console's lags stay at 0.6 to 2.1 ms. The work is
  erXos's, the bands of docs/design-fiasco.md ("Bands", "Urgency", "Scheduling"); the levels, the bands and the
  grant's 1 ms slice as the quantum are built, and what remains is one normal scheduler pinned to each CPU, parks in
  place of spinning, and an executor that holds work of priority `high` raised above every domain's ordinary work.
  Which threads the owner waited behind is not recorded, so the
  Pi 4's measurement of that document's "Verification" is run as each lands.

* [Medium] Fiasco backend, `liberx/backend/fiasco/park.c`: `erx_park` and `erx_group_take_ready` refuse a thread
  that is not an executor (`ERX_ETYPE`), and that is all of the executor rule. Refusing to arm a vCPU
  upcall on an executor, and refusing an executor every other blocking wait with `ERX_EWOULDBLOCK`
  ([design-fiasco.md](design-fiasco.md), the blocking-call row, FD18), are not built, and
  `ERX_EWOULDBLOCK` is not defined in `abi/erx_abi.txt`.
* [Low] Fiasco backend, a task's first check of a release file still hashes on the service
  thread (`liberx/backend/fiasco/slice.c` `erx_fiasco_release_entry_body`, `check == 1`), so
  every other call of every task and of the root waits for that file's hash. The website's
  domain releases hold only small files (the largest 37 KB), so each wait is short; a release
  that ships a file of megabytes would hold every task's calls for the hash, and with them any
  wait of the system domain's normal scheduler on the service (the allocator's, below). The
  task could hash its file over its own mapping of
  the slice, with the file's hash in the reply, and the verdict then be the task's own.
* [Medium] Fiasco backend, no test reaches the service's refusal of an image entry without a
  good verdict (`liberx/backend/fiasco/slice.c` `erx_fiasco_slice_image`, and
  `erx_fiasco_task_image_map_body` making the slice before `erx_image_plan` reads the entry):
  the root's `erx_image_map` checks first, so no suite sends the service an unchecked image
  entry, and deleting either guard fails nothing. A native_space case that calls
  `erx_fiasco_service_call(ERX_FIASCO_CALL_IMAGE_MAP)` directly for a damaged image entry and
  expects `ERX_ECORRUPT`, seeded once with the guard removed, would pin both.
* [Medium] Fiasco backend, the website's image under TCG with `-icount shift=9` and
  `erx.watchdog=1,30,600` reaches the rc banner, but none of its configured domains reports
  ready in time: network and storage are stopped and restarted from about 1100 s uptime until
  each is left down. Decide whether the ready deadline should scale with the machine. A stop's
  teardown takes 20 to 35 s there, about half in Fiasco's unmaps of the task and half in the
  root's walk of its range table, over about 272,000 pages of reserved addresses per domain;
  the service runs it in pieces between other calls, so the restarted domains' calls do not
  wait behind it, but their start waits for the exit record that ends it.
* [Medium] Fiasco backend, a long service body holds the system domain's watchdog pet off
  whenever the one normal scheduler makes a service call during it. A stopped domain's
  teardown runs in pieces (docs/design-fiasco.md, "Task exit"); on the same TCG boot (Apple M3
  Max, QEMU 11.1.3, Homebrew clang 23.1.3, one CPU, `-icount shift=9`) a stop's longest pet
  gap is 2.2 s at the median of 25 stops, 3 over 5 s, the worst 17.9 s, which starts 4 s after
  the stopped domain's exit record, while it restarts, against 3.1 s at the median of 19, 9
  over 5 s and the worst 21.7 s with the teardown as one body. What holds the remaining gaps
  is not yet attributed: the longest piece left, Fiasco's deletion of the emptied task, takes
  1.5 to 4 s there (it walks every page table the task touched), a space's release and a
  budget's destroy finish their spaces' teardowns in one body, and the restarted domain's own
  start runs beside them.
  - What holds it: a table of each root thread's current service call, read through QEMU's
    monitor during a 22 s gap of the one-body teardown, shows the normal scheduler in
    `erx_vm_reserve < os_mmap_aligned`, ERTS's allocator taking a carrier.
  - Every other service call a normal scheduler makes is the same: `erl_mmap.c`'s `erx_vm_*`;
    the port drivers' (`erx_lane_drv.c`, `erx_program_drv.c`); the setup NIFs of `erx_pipe_nif`
    (`make_lane`, `make_bell`, `close`, `hand_make`, `open_end`), `erx_area` (`map`, `lend`,
    `unlend`) and `erx_device` (`open`, `irq_bind`, `irq_bind_owner`, `queue_create`,
    `region`, `framebuffer`, `negotiate`), which could take the dirty I/O flag once each is
    checked on a dirty thread; their per-event doorbells and acknowledgements, where the flag
    would cost every event; their resource destructors, which the garbage collector runs; and
    a page fault, since the service is the root's pager.
  - Which NIFs must be dirty is a list kept by hand, the C tables and the probe of
    `test/integration/runtime_service_nifs_test.rb`. Counting the root's executor-class
    service calls by number in `erx_fiasco_service_call` and showing the count as an
    inspection path would let a QEMU test hold an allowlist.
  - The fix of the class: the root's own memory calls stop waiting behind other tasks' bodies
    (a super carrier reserved and committed at start, or the root's calls on its own table run
    in the calling thread), or no service body stays long, as the stepped teardown does for a
    stop.
* [Medium] Fiasco backend, `erx_fiasco_vm_task_shed` (`liberx/backend/fiasco/vm.c`): that no
  page of a teardown piece returns to the pool while the task maps it rests on the caller
  unmapping the piece by flexpages before `erx_backend_vm_shed` runs with no effects, an order
  of two lines no host test sees; `check_shed` and its mutants cover only the core's per-page
  unmaps. A range-unmap effect that `erx_backend_vm_shed` calls before it gives pages back
  would put the order in the core, where a mutant can prove it.
* [Low] Fiasco backend, fault records (`liberx/backend/fiasco/service.c` `service_page_fault`): a
  memory fault's `cause` is Fiasco's access bits (`mr[0] & SERVICE_FAULT_ACCESS`), not the cause
  as the CPU reported it, which [design-kernel.md](design-kernel.md) gives for every fault
  record; the domain service's end line prints it as is. Pass the exception syndrome for a page
  fault where Fiasco hands it over, or state per kind what `cause` holds, with a test.

* [Low] Fiasco, bootstrap (`fiasco/bootstrap/server/src/platform/arm_virt.cc`): `init`
  never calls `query_psci_method()`, so `reboot_psci` uses the default `Psci_smc`
  (`platform-arm.h:96`) while QEMU virt's device tree says hvc; bootstrap's own reboot path on
  virt would issue SMC through the wrong conduit. The fix is one call in `init`, with a test.

* [Medium] hosted runtime test, network rows (`test/integration/runtime_hosted_smoke_test.rb`,
  `test_init_runs_from_the_archive_alone`): the rows `gen_tcp:listen(0, [])` (expects `{error,enotsup}`, which
  `erx_gen_tcp:listen/2` does not answer: it asks the grant) and
  `gen_udp:open(0, [])` (expects an `erx_gen_udp` socket) assume the system release ships `erx_net`, but it has
  not since the stack left the system domain (`ReleaseFiles::SYSTEM_APPLICATIONS`), so the first answers `undefined
  function erx_gen_tcp:listen/2` and the test fails; `erx_gen_tcp` also exports `listen/2` now. Decide what
  gen_tcp and gen_udp answer in a domain that ships no network code (an undefined-function exception is no
  answer a caller can handle) and pin that, and move the backend rows to a domain that holds the network.
* [Low] upstream, the run queues' wakeup-other check (`otp/erts/emulator/beam/erl_process.c`,
  `wakeup_other_check`): stock OTP 29.1.2 lets a dirty queue's `int` counters grow until they wrap (its dirty
  CPU calls are charged their elapsed time, and every dirty call at least 400 reductions), and for `+swt low`
  and `very_low` shifts left by a negative count. erXos's copy fixes both (edit 70 of
  [design-runtime.md](design-runtime.md#the-edits-outside-syserxos)). Report it upstream.
* [Low] upstream, BeamAsm (`otp/erts/emulator/beam/jit/arm/ops.tab`, `jit/x86/ops.tab`): stock OTP 29.1.2's JIT
  turns the small-integer half of a `select_val` that also matches a bignum into a jump table whose gaps branch to
  the NIL immediate, so a small integer in a gap kills the emulator (SIGBUS on AArch64). erXos's copy gives such a
  select a search instead. `beam_SUITE:select_val_mixed/1` is skipped on stock's JIT, and the generator of
  `erx_prog:status/1` (`tools/lib/erx/abi_emit_erlang.rb`) keeps its signal clauses in a function of their own,
  since the host tests run that module on stock. Report it upstream.
* [Low] upstream, ERTS signals (`otp/erts/emulator/beam/erl_bif_info.c`, `is_process_alive_1`): a
  process monitor is held as its scheduler's pending signal until the monitoring process sends
  that target another signal, creates another process monitor or is scheduled out
  (`proc_queue_signal` in `erl_proc_sig_queue.c`), and `is_process_alive/1`'s fast path answers
  without sending it. `erlang:monitor(process, P)` followed by `is_process_alive(P)` can answer
  `true` and the monitor then report `noproc`, against the guarantee `is_process_alive/1`
  documents (every earlier signal from the caller reaches P before the check); seen on the stock
  OTP 29.1.2 oracle build. When the caller's pending signal is to P, take the trap path or send
  it first (`erts_proc_sig_send_pending`), and report it upstream.
* [Medium] Fiasco, the early panic (`fiasco/kernel/src/kern/arm/bsp/gen/reset-arm-gen.cpp`,
  `kern/arm/startup-arm.cpp`): a panic before `Psci::init` and `Dt::init` in `Startup::stage2`, the handoff
  checks of `erx/erx_handoff.cpp` among them, finds no reset method, since `platform_reset` tries PSCI only once
  it is detected and the device tree's reset only once it is read, and loops forever, so a kernel built without
  the debugger, as the release kernel is, hangs instead of rebooting. Probe PSCI from the device tree in `platform_reset` when it is not yet initialized; the test boots
  under QEMU with `-no-reboot` a kernel whose handoff check fails and expects QEMU to exit after the panic line,
  and its seeded failure leaves the probe out.
* [Medium] Fiasco build on a FreeBSD host, `tools/lib/erx/fiasco.rb`: the Kconfig step now builds with `cc`
  (`HostOs::HOST_CC`) and the users build is given `HOST_CC`/`HOST_CXX`, but `tools/erx build fiasco` has not been
  run through to an image there; run it on the FreeBSD test host and fix what stops it, then delete this item.
* [Medium] Fiasco backend, `liberx/backend/fiasco/service_task.c` (`erx_fiasco_task_create_body`):
  a create from a task other than the root is not refused, though the call table and the
  deferred table say `ERX_ENOTSUP` in 1b-A (docs/design-fiasco.md, `erx_space_create`), so a task with a fault
  gate of its own makes Fiasco tasks and spends the service's task rows; the child stays
  inert, since a thread or an image map into it is root only. Refuse it and add a
  `native_task` case. More widely, "root only" is a check in each body (`cap_pass`,
  `image_map`, `slice_create`, `task_join`, the thread and IRQ bodies, the physical and
  contiguous creates), and this one was missed: give each call a caller class in
  `erx_fiasco_wire_words`' table (`service_wire.c`), refuse wholly root-only calls in
  `erx_fiasco_wire_decode`, and hold the table to the call table's root-only rows with a
  host test, leaving only the partly root-only calls' checks in their bodies.
* [Medium] liberx Fiasco backend, `test/guest/native_task` (`case_ends("service", ...)`): the first
  case hung once under HVF with one CPU, after `erx: task: cpus 1` and before the case's line, so
  `task-service` timed out; the rerun on the same tree passed on one and four CPUs. The task that
  `erx_fiasco_launch` starts with `ERX_SPACE_JIT` and `MODE_SERVICE` never ended, so the root's
  join waited for good. Find the wait it stuck in. The case's rewrite rounds yield on one CPU, and
  with the fork's yield (docs/design-fiasco.md, "Scheduling") the case takes well under a second
  of its 30 s, so a timeout there is a hang, not a slow run.
* [Medium] liberx Fiasco backend, `launcher.c` `erx_fiasco_task_join_until` and `object.c`
  `erx_fiasco_object_drain`: a task holding the last handle of its own space's budget is deleted in
  the request that ends it, its ended semaphore with it, so a root join that got `ERX_EBUSY` before
  the end waits on a deleted (or, after a new space takes the index, another task's) semaphore:
  `erx_fiasco_semaphore_down` retries the IPC error until its deadline, or for good. The domain
  library keeps its copy of every domain's budget, so only a caller that moves its last copy away
  meets it. Have the service up the joiner's own semaphore, as the other blocking stubs do.
* [Medium] liberx Fiasco backend, `service_task.c` `task_teardown`: a task's end defers only what its
  handle table's close frees or what it created (`object_later`); memory whose last mapping goes and
  the home group still end inside the teardown, safe only because neither kind's end stops a task.
  Route those ends through the mark too, so nothing ends inside a teardown, and drain once after
  `service_main`'s dispatch rather than in three arms.
* [Low] liberx Fiasco backend, `object.c` and `core/handles.h`: rename the record's `ending` word
  (`end_pending`) and `object_later` (`object_defer_end`), since `budget.c` uses "ending" for an end
  in progress, and word the core header's comment without naming the Fiasco backend.
* [Low] liberx Fiasco backend, `budget.c` `budget_sweep`: a budget's object sweep ends a group
  charged to it whose home task, charged to another budget, still has threads, which `erx_object_destroy`
  and a last close refuse ("a group never goes before its threads"). Skip such a group in the sweep, or
  stop its home first.
* [Low] liberx Fiasco backend, `object.c` `erx_fiasco_object_end`: it does not itself refuse a kept
  record (the time page, an image entry's slice); only `erx_fiasco_object_destroy_body` does. No caller
  reaches a kept record through an end today, so the guarantee rests on each end path. An end that did
  reach an image slice would also leave `service_task.c`'s slice cache (`task_image_slice`), which holds
  a bare record index, naming a freed or reused record, possibly another entry's slice. Make the end
  refuse a kept record, so the keep holds whatever calls it; no test destroys the time page's handle
  to check destroy's own refusal (`ERX_ERIGHTS`), so add one to `native_space` with it.
* [Medium] liberx Fiasco backend, `liberx/backend/fiasco/service.h` (`erx_ipc_wait`): the Fiasco backend's
  open wait returns design-kernel.md's tag and label, but only for fault and exit records, the one
  message its gates carry. Decide whether BK8b's IRQ deliveries share the same open wait before
  any thread other than the gate worker (`sys/erxos/erx_gate.c`), which binds only the domain's
  fault gate, waits in it.
* [Medium] Fiasco backend, `sys/erxos/erx_program_drv.c` (`PROGRAM_IMAGE_CAP_LIMIT`) and
  `liberx/backend/fiasco/object.c` (`erx_fiasco_object_task_open`): a program's image is made with a
  table of `caps_max` capabilities, so it holds every copy of its pipe hand-offs, and the Fiasco
  backend grows the table as it fills from `erx_fiasco_vm_records`, whose pages come from
  `erx_fiasco_pool_take` on the backend's shared pool (`liberx/backend/fiasco/vm.c`, `vm_record_take`),
  charged to no budget. A program that duplicates its own capabilities therefore grows its table from
  the shared pool, up to `caps_max` entries, past its own budget, and can empty the pool, after
  which another program's install pass is refused and that program is stopped
  (docs/design-pipes.md, "Hand-offs"). A Phase 1 residual, not to be rebuilt
  in user mode: erXos's kernel charges a table's growth to the space's budget.
* [Low] Fiasco backend, `liberx/backend/core/park_table.h` (`listed`) and `park_table.c`: a group holds at
  most 64 IRQ objects, since `listed` is a 64-bit map with one bit per object and the file
  asserts `ERX_BACKEND_PARK_OBJECTS_MAX <= 64`. A group that would need a 65th doorbell is refused with an error:
  the session's group, which holds one per program port (`erx_program_drv.c`), the connections' bells and
  every end a session process holds, so a session runs about 30 programs with writers; or a program holding
  64 or more pipe ends and its channel bell. The 65-writer case therefore waits for erXos's kernel. Not worked around
  on Fiasco.
* [Medium] Fiasco backend, `liberx/backend/fiasco/irq.c` (`ERX_FIASCO_IRQS_MAX`, 256, `abi/erx_abi.txt`): the machine holds at most
  256 IRQ objects, one per program channel doorbell, one per pipe end and so on; an object past it fails
  with `ERX_ENOMEM`. Busy sessions with many programs and pipes can reach it. The table is machine-wide and
  not shared out: clause 9 of design-packaging.md's property 19 does not count it, so one domain's objects
  can take every entry and leave a configured domain's restart without one. erXos's kernel has no such
  table.
* [Low] Fiasco backend, musl's seam (`musl/src/internal/erxos/syscall.c`, `musl/src/thread/erxos/clone.c`): it
  includes the backend's own headers (`thread.h`, `service.h`, `vm.h` and others), which
  `fiasco-backend-headers-private` allows for it alone, so a backend header that grows an l4 include breaks
  libc.a. A neutral liberx header carrying only what the seam calls would take musl off that allow-list.
* [Low] hosted backend, `liberx/backend/hosted/group.c` (`irq_objects`): the hosted backend holds 64 IRQ
  objects in total (`ERX_BACKEND_PARK_OBJECTS_MAX`), so a hosted run with many programs and pipe ends
  fails earlier than the QEMU runs do.
* [Low] hosted backend, `liberx/backend/hosted/refused.c`: a hosted runtime runs no programs; the
  channel's first memory object is refused, so `erx_program:start/1` answers `{error, enotsup}`.
  Programs in hosted mode need the hosted backend to make spaces and pass handles.
* [Medium] liberx Fiasco backend, `liberx/backend/fiasco/fault_gate.c` (`erx_fiasco_gate_fault`): a
  fault takes any free entry of its space's pool, since Fiasco's fault message names only the task, so
  its record's thread is unknown and design-fiasco.md's "a fault in its thread's record" does not
  hold. A task that reaps a faulted thread and faults again at that index can run its pool out, and
  later records are dropped. A Fiasco gate per thread, labelled with task and index, as each thread's
  pager would name the thread and make the bound hold by construction; decide whether that is worth it
  on Fiasco or a residual until erXos's kernel.
* [Low] liberx Fiasco backend, `liberx/backend/fiasco/fault_gate.c` (`gate_space.dropped`): records a
  gone gate drops are counted but nothing reports the count; the inspector's space report (SV4) should
  show it.
* [Low] liberx Fiasco backend, `liberx/backend/fiasco/budget.c` (`erx_fiasco_budget_named`): a
  create whose budget is `ERX_CAP_NULL` charges the caller's own budget, as `ERX_CAP_SELF` does, because
  about fifty callers (the launcher, `erx_device.c`, the function_api and native_space guests) still pass 0.
  `erx_budget_create`'s parent is read the same way. Move them to `ERX_CAP_SELF` and refuse `ERX_CAP_NULL`
  with `ERX_ETYPE`, on the hosted backend too.

* [Medium] Fiasco backend, `liberx/backend/fiasco/budget.c` (`budget_takes`): a budget's end takes a group charged to it while the group's home task still runs, when that task's space is charged elsewhere, so the home loses its group and its doorbells stop delivering; design-fiasco.md's "Budgets and groups as records" says the first sweep stops the home task of every such group instead. Any task can now build this. Either stop the home in the spaces sweep, or refuse at `erx_fiasco_group_admit` a home whose space is not below the group's budget; add a native_space case first.
* [Low] Fiasco backend, native_space and native_task suites: no case checks that a task's end frees the budgets, groups and doorbells it made (the drain path), since the root's checks count pool pages only, not IRQ slots or object records; add a root-side count of live IRQ slots and records.
* [Medium] liberx Fiasco backend, `liberx/backend/fiasco/task_refused.c`: in a task,
  `erx_vm_free_pages` reports 0 while commits through the service still succeed, an
  invented count that `api.h`'s exact contract does not allow; it should answer
  `ERX_ENOTSUP` (the call needs a status return) or the domain budget's room.
* [Low] Fiasco backend, `liberx/backend/fiasco/object.c` (residual of K25): a destroyed object's
  entries in other tables stay stale until their holder closes them, so a refused connect
  leaves up to three stale entries in each party's table that the party never learns, and a
  disconnect leaves the party's three to close. erXos's kernel clears them at the delete;
  Fiasco is not to rebuild that. The library's own close after a destroy relies on the
  Fiasco backend's stale entries too: under K25 that close names a freed slot, so the Phase 2
  library must not close what a delete already cleared.
* [Low] liberx Fiasco backend, `liberx/backend/fiasco/service_task.c` (around line 354): `erlang:halt/1`
  with a slogan in the system domain writes no crash record, since the root task's own stop takes the end
  path with no fault; [design-system.md](design-system.md) "The crash record" gives a halt the cause
  `halt`. musl's `abort()` meanwhile ends in a store to address 0, because `tkill` answers `ENOSYS`
  (`musl/src/internal/erxos/syscall.c:290`), so an abort reads as a fault rather than as an abort.
  The system_domain suite's re-grant boot kills the system domain with `erlang:halt(abort)` and holds
  its crash record to that write to address 0 (`Regrant.judge`), so a fix here changes that judge too.
* [Low] Fiasco build, `fiasco/bootstrap/server/src/Make.rules:1` and `fiasco/kernel/src/Makeconf:395`: their
  comments cite `docs/design-stopgap.md`'s "Boot handoff" and "Interfaces", sections that live in
  `docs/design-fiasco.md`. Both files are recipes pinned by hash in `config/provenance/fiasco-generation.json`, so
  correct the citations when the recipes are next re-pinned.
* [Medium] Fiasco build, `tools/lib/erx/fiasco_inputs.rb`: every file under `liberx/` is an input of the user
  build, so an edit to any native-root source (`liberx/backend/fiasco/console.c`, which the user build does not
  compile) discards `build/fiasco/users` and rebuilds it from scratch, about 75 s of a 300 s `medium_boot` run on a
  loaded host. Capture for each component only the C17 sources its cores read (CoreArchive), so such an edit reruns
  only the native compiles that read it.
* [Medium] Fiasco build, `tools/lib/erx/fiasco.rb` `build_image`: what reads `build/fiasco` (image packing,
  QEMU, the native compiles against its headers and libraries) holds no lock, and on a host that reuses no record
  (FreeBSD) a later `Fiasco#build` runs make again and rewrites `images/bootstrap.raw` in place, so a reader in
  another process can see a short image; `prepare_source_cache` rewrites `.erx-inputs.json` in place and, when the
  inputs change, removes `kernel`, `users`, `source` and `images` whole, on every host. Builds already take turns under `build/fiasco/.lock`; give readers a
  shared hold of it, as `Runtime.reading` does for `build/runtime`, and publish the image and every other rewrite
  under `build/fiasco` by rename.
* [Low] `tools/lib/erx/fiasco.rb`: `Fiasco#build` records the audit report again before pack audits it, so a build output edited after the build, which `make` leaves alone, is recorded as built rather than refused. (From reading the code; not run.)
* [Low] hosted, `erlang/apps/erx/src/erx_stdio.erl`: the hosted console's driver cannot start twice: `init/1` loads
  its NIF on every start, the second load is refused, `start_nif` refuses a second start, and the reader thread
  signals the first driver's pid. So `erx_console_sup`'s restarts of a hosted console all fail at once and it gives
  up, leaving the hosted runtime without a console. Load the NIF once (`-on_load`) and let a start move the input to
  the new driver.
* [Low] Fiasco bootstrap, `fiasco/bootstrap/server/src/erx_image.cc` (`erx_boot_args_cut`): a command line over
  `ERX_BOOT_STRINGS_MAX` (2,048 bytes) is cut at its last whole word without a word on the console, where
  docs/design-kernel.md ("Configuration") says the boot reports the cut. Handed a 2,375-byte line naming every stdlib
  suite, the QEMU oracle's guest ran only the suites named in its first 2,048 bytes, and its serial log said nothing. Print the cut, with both lengths, and
  check the line in a boot transcript test.
* [Low] Fiasco bootstrap, overlapping RAM regions:
  `Region_list::optimize` (`fiasco/bootstrap/server/src/region.cc`)
  merges a region into its predecessor by setting the predecessor's end to
  the region's end, so a region wholly inside its predecessor shrinks the
  predecessor and drops RAM. Only the EFI memory-map path adds RAM with
  overlaps allowed (`efi-support.cc`, `ram->add(..., true)`), so QEMU
  `virt` booted from a device tree is unaffected. Found by reading, not
  reproduced; fix with a regression test before any EFI boot path is used.
* [Low] Fiasco backend, `liberx/backend/fiasco/irq.c` (`IRQ_MSI_DOORBELL`): the MSI frame's doorbell offset, `0x40`,
  and the message data equal to the line are hand-copied facts of one frame type, which the Raspberry Pi 5's MIP
  breaks. Implement the frame's doorbell register, `data` and start writes that the packer derives from the frame's SVD
  file, and the doorbell's bus address that the root derives at boot from the frame's bridge's inbound windows in the
  tree the firmware handed over ([design-pcie.md](design-pcie.md#the-msi-frame-on-fiasco)), so the root holds no
  frame-type fact; the `native_irq` guest's `MSI_DOORBELL` goes with it.
* [Medium] Fiasco boot, `kernel/core/boot_place.c`: `bootstrap` places two
  entries the target design does not have, `boot/sigma0` and `boot/fiasco-root`,
  because the kernel still starts sigma0 and a root task from its information
  page; sigma0 pages that root with read, write and execute over its
  whole range, since one range cannot tell its segments apart, gaps between
  segments included, which nothing zeroes. Delete both roles, their ABI paths and the record of the recipe in
  `tools/lib/erx/boot_image.rb` when the kernel maps the root task from the
  startup plan. `tools/lib/erx/boot_image.rb` builds on the test fixtures'
  empty manifest until production packing lands.
* [Medium] Fiasco boot, `kernel/core/boot_place.c`: the handoff record's
  `pool_usable`, `pool_heap` and `pool_regions` are zero and `kmemsize` keeps
  Fiasco's default until `erx_pool_plan` and `abi/backend/fiasco.txt` land; the
  kernel does not read them yet. `kip_size` and the kernel's alignment are limits
  of `abi/erx_abi.txt` until that backend file exists to hold them.
* [Medium] Fiasco boot, `fiasco/bootstrap/server/src/init_kip.cc`: `init_kip_md`
  writes the memory descriptors at the offset the kernel image's information page
  names, unchecked against the view's size or its count, though
  [design-fiasco.md](design-fiasco.md#boot-handoff) says within the view.
  Only a kernel image whose hash matched gets there, and a kernel image already
  runs in kernel mode, so this is a crash on a bad build and no gain. Check the
  offset and count in the plan or just before the write, with a fixture.
* [Medium] Fiasco boot, `tools/lib/erx/boot_image_check.rb`: two cases of the
  verification table are not run on QEMU: a single file whose header asks QEMU to
  place it away from `bootstrap`'s link address, and a boot with the validator
  removed. The first needs the harness to expect a deadline, the second a seeded
  first stage.
* [Low] Fiasco boot, `fiasco/bootstrap`: the inherited image tools and module
  code (`build.pl`, `exec.cc`, `module.cc`, `boot_modules.cc`, `mod_info.cc`,
  `uncompress.cc`, `mk/tool/imagebuilder`) are unbuilt and the other platforms'
  sources still name them. Delete them or fix those platforms with the first
  port that needs one.
* [Medium] Fiasco kernel, FP state: the fork switches FP state eagerly,
  and nothing runs it. No QEMU case holds distinct vector registers in two
  threads of different spaces across switches and a migration, or reads a
  fresh thread's registers as zero (the FP state case of "The release's
  cases" in [design-fiasco.md](design-fiasco.md#the-releases-cases)), and no
  `tools/erx bench` workload times the kernel's context switch, so the
  eager switch's cost is unmeasured. `Context::spill_fpu_if_owner`
  (`context.cpp`), which turns the unit on to save a current vCPU that
  disabled its FPU, has no case that reaches it, and the eager
  `Thread::transfer_fpu` (`thread.cpp`) still saves and restores the
  current thread's registers without turning the unit on; the design
  does not build it.

## Security residuals

* [Low] Fiasco kernel, upstream fixes taken at 07ea18e1 that no erXos call reaches, so no case tests them
  ([design-fiasco.md](design-fiasco.md#upstream-security-fixes) asks a test of a reachable fix). The root alone
  maps memory, each map from the page's one window mapping and none a grant (`vm.c`, `vm_map`); a domain holds no
  task, factory or thread capability, and the root's receive window takes no map item (`vm.c`, `device_map`); only
  the service controls threads, and it runs each after its `ex_regs` (`service.c`, `service_thread_steps`). So:
  8bded60d's grant of a mapping that has a submap (`mapdb.cpp`, `Treemap_ops::mem_size`) is never made, and no
  factory of the backend has a quota of its own, so every submap is charged to the root's one quota; 4be34cdc's
  flush of a receiver mapping that precedes the sender's in one tree (`map_util.cpp`, `map`) never runs, since
  every other mapping of a page is a child of its window mapping, which a map over it updates in place; d7cbdc42's
  frame partly covered by a flush range that runs past its end (`mapdb.cpp`, `Treemap_ops::flush`) no caller
  makes, since every flush range is a naturally aligned flexpage, which a frame either holds whole or lies within;
  and 70d3a306's restart of a killed thread and kill of a never-started thread on an online CPU need a run before
  `ex_regs` or a second controller. A change that makes one reachable (a grant, a domain's own task capability, a
  run before `ex_regs`) brings that fix's case and seed with it. 09be8ba9 has its case, `native_threads`'
  `unstarted_deleted`, seeded by `ERX_TEST_KILL_UNMIGRATED`.
* [Low] Fiasco backend, a failed start after `ex_regs` (`liberx/backend/fiasco/service.c`, `service_thread_steps`):
  the thread is deleted with no CPU to complete its kill on, so its index stays lost until the task ends and the
  reference the kill takes stays held. Running `l4_scheduler_run_thread` before `ex_regs` would leave every failed
  start a never-started thread, whose kill Fiasco completes; unverified until `unstarted_deleted` with its starts
  failing at step 3 shows whether the indices come back.
* [Medium] Fiasco backend, the on-board pin window (`liberx/backend/fiasco/bcm2711_pins.c`, `vm.c`): the root maps
  the pin controller's page with `erx_fiasco_vm_device_page`, whose mappings last the root's life, so GPFSEL0 to
  GPFSEL5 stay writable in the system domain after boot. That no second writer exists then rests on the root calling
  the setter once and on no stray store in the system domain's runtime. Deleting the root's write with the pin
  driver's landing closes this ([design-pinctrl.md](design-pinctrl.md#what-the-code-does-today)): the page then has
  one mapping, the driver's.
* [High] Fiasco backend, rights per handle (`liberx/backend/fiasco`, `liberx/backend/core/handles.h`), blocks
  0.2: the design records erXos's rights in every handle entry, intersects them with the mask on a duplicate
  or a pass, and checks the right each call needs in the one lookup ([design-fiasco.md](design-fiasco.md#rights),
  the call table's `erx_vm_map` row: a right the caller's entry lacks is `ERX_ERIGHTS`). The entries record
  rights and the core's lookup checks a needed right (`handles.c`), but a create records its type's whole mask, a
  carve is a create, and `erx_fiasco_object_find` asks for no right, so the only right enforced is destroy, as
  creator-only (`object.c`, `erx_fiasco_object_destroy_body`). So a domain maps read-write, or `erx_mem_copy`s into, any memory object it
  was passed read-only: a connection's peer side, a program's lane side, a pipe's ring
  (`vm_rules.c`, `erx_fiasco_vm_map_rule` and the copy rule check only kinds; `service_task.c`,
  `erx_fiasco_task_vm_map_body` checks only that the caller holds the handle); it passes a handle onward with
  rights it never had, since a later pass's mask narrows nothing; and the pass reports in each item's
  descriptor rights it does not enforce (`object.c`, `object_pass_item`: `mask & erx_ktype_rights_mask(type) &
  ~ERX_HR_DESTROY`), a reported value that is not true. Read-only sharing does not exist on this backend.
  Development builds run trusted code only; the gap blocks release. The work is the third part of the
  design's [Verification](design-fiasco.md#handles) note: the entry's rights set at create from the creation kind's default set in `abi/kernel.txt`, at a carve intersected with the parent
  entry's rights and `DESTROY`, intersected in `erx_backend_handle_dup` and `object_pass_item`, and a needed-right
  argument to `erx_fiasco_object_find` passed on to the lookup, so every call gets the check by construction; the *rights shrink*, *a
  creator's pass* and *writable peer side* cases, and a budget carved through an entry without `SPACES`, with their
  seeded faults. A duplicate's mask needs a path end to end, since `erx_cap_dup` takes none (`service.h:132`) and
  its request carries only the caller and the handle (`abi/erx_abi.txt`, `erx_fiasco_cap_request`): give
  `erx_cap_dup` the mask erXos's kernel's call takes (`include/erx/cap.h`), a generated request with a mask field,
  the decoder and the dispatch (`service.c`, `ERX_FIASCO_CALL_CAP_DUP`) passing it to the body, and its callers
  passing their masks.
* [Medium] Fiasco backend, placement rights of the request gate and the thread semaphores
  (`liberx/backend/fiasco/service_task.c:306-308`, `service.c:732-734`): both are mapped into the task with
  `L4_CAP_FPAGE_RWS`, where the design places the gate with the send right alone and a semaphore with only the
  rights `l4_semaphore_up` and `_down` take ([design-fiasco.md](design-fiasco.md#who-holds-what)). The
  special right S is the one Fiasco's `Ipc_gate_ctl::bind_thread` requires on the gate, and a bind rewrites the
  gate's label (`fiasco/kernel/src/kern/ipc_gate.cpp:301-345`), so a task holding its gate with S may rebind it
  away from the root service and relabel it. Whether a task can complete that rebind, which needs a thread
  capability with S named through the call's typed item, is unverified: the lookup lives in a Fiasco header
  erXos does not read. If it can, it most likely harms only that task. Map the gate without S, since a send
  needs no right (`ipc_gate.cpp:471-512`), and each semaphore with what up and down need.
* [High] Fiasco backend, `liberx/backend/fiasco/service.c` (the `ERX_FIASCO_CALL_TIME_SET_OFFSET` case),
  blocks 0.2: the dispatch passes the body the request's `offset_ns` alone, never its `caller`, and checks
  no right, so any task sets the wall clock, against 0.2's contract that an app cannot
  ([design-fiasco.md](design-fiasco.md), the release's cases) and the root's `WRITE` check of
  [design-time.md](design-time.md#on-fiasco); certificate checks follow the clock. Pass the caller, check
  `WRITE` on its time-page handle, answer `ERX_ERIGHTS` without it, with a backend case.
* [Low] Fiasco backend, the Pi 4's hardware watchdog (`liberx/backend/fiasco/watchdog_thread.c`): a Fiasco panic
  resets through PSCI's system reset on the panicking CPU alone, and TF-A's BL31 makes it by writing WDOG with
  10 ticks, about 153 us (`plat/rpi/common/rpi3_pm.c`, `rpi3_watchdog_reset`). The root's watchdog thread, still
  reloading once a second on another CPU, writes 4 s back if its reload lands inside those 153 us, and then keeps
  the board up for good: about one panic in 6,500. Likewise a liberx end on another CPU racing a reload can
  delay its reset by one 4 s timeout, once. Fiasco without JDB has no way to park the other CPUs before the
  reset: every MP kernel receives the debug IPI, but only JDB sends it and parks the CPUs it stops. A fix
  in liberx alone: read WDOG before each reload and stop for good when it holds far less than our last
  write can leave, which needs the fact that a WDOG read returns the time left (unverified in the facts
  record). Whether 0.2 publishes the race as a downside or fixes it is open.
* [Low] Fiasco, the release kernel's fatal trap (`fiasco/kernel/src/kern/arm/thread-jdb.cpp`,
  `[arm-!debug]` `call_nested_trap_handler`): a trap inside its own path, in the console's UART or in
  `platform_reset`'s mapping, enters the handler again without bound until the kernel stack overflows,
  instead of resetting. JDB guards the same case with `nested_trap_recover`; a flag set on entry that
  sends a second entry straight to `Psci::system_reset` would close it.
* [Medium] Fiasco backend, system domain device access: the system domain's ERTS runs in the root task, so
  `erx_device` may open any physical window (`service_task.c` checks only that the caller is the root)
  and the device NIF's table holds `pm_wdt`'s RSTC and WDOG as generic registers (`ownedByNif false`).
  A module the `erx_device` chokepoint admits can therefore stop or reprogram the Pi 4's hardware
  watchdog, or write the rest of the power-management block. Marking both registers `ownedByNif true`
  closes the NIF table route; the physical-window route needs the open checked against the manifest.
  The firmware mailbox's unit, which the system domain holds so the root can map it
  (`liberx/backend/fiasco/vc_mbox.c`), is open to the same route, and with it the board's key (PL2): mark
  `vc_mbox.svd`'s registers `ownedByNif true` and refuse its window in the same check. Neither closes a third
  route: the root keeps the mailbox's page mapped for the boot in the address space the system domain's ERTS
  shares, so a memory error in ERTS or a NIF there can post a property request, a key read among them, with no
  `erx_device` call; the watchdog's page is the same. FD29's row of `docs/design-fiasco.md` should name it.
* [Low] Fiasco backend, Fiasco's vCPU state area ([vCPU upcalls on Fiasco](design-fiasco.md#vcpu-upcalls-on-fiasco)):
  the area lives in kernel-user memory its program can write, so a program can set its own pending flag or rewrite
  the saved frame it is resumed with. It harms only that program, since `erx_vcpu_resume` validates the frame and
  Fiasco sanitizes the processor state it restores; acceptable for Phase 1's trusted domains, and gone with erXos's
  kernel, which reads user-writable state only through accessors that load each field once.
* [Medium] Fiasco backend, `liberx/backend/fiasco/root_open.c`: the root's read-only copy of the device tree keeps `/chosen`'s
  `rng-seed` and `kaslr-seed` for the boot's life, so code in the root task (the system domain's ERTS, a NIF) can read
  through `erx_boot_tree` the bytes that seeded the generator; erXos's kernel zeroes them before any space sees the tree
  ([design-device-tree.md](design-device-tree.md)). The harness's boots from a dumped tree (`seeded_stdout_tree`
  in `tools/lib/erx/production_image.rb`, `tools/lib/erx/net_device.rb`) may replay a seed stored on disk; unverified.
  The root also erases its stack copy of the seeds only after `erx_fiasco_root_up` has started the service thread.
* [Medium] Fiasco, Phase 1b's deferred guarantees: every guarantee the
  user-facing system on Fiasco rests on but does not get is a row of
  [Downsides against erXos's kernel](design-fiasco.md#downsides-against-erxoss-kernel),
  with the milestone that closes it; that table is the one list. Those that
  untrusted input reaches: unconfined DMA (M9's kernel part, M11), where a
  device can write any page, so every driver domain (storage, network,
  display) is in the trusted base, beside the network domain's packet parsers
  and the display domain's draw clients, and no bounce buffer, software IOMMU
  or address filter is built in user mode; the network domain's CPU grant and
  per-interface ingress budget, which are records on Fiasco, so a flood
  from the wire can take CPU from other domains (M5's kernel part, M8); no wall around any domain, the browser-facing
  web domain included (M5's kernel part); and nothing stopping a domain or
  program that bypasses `liberx` (M5's kernel part, M7); and, on the
  Raspberry Pi 4 (1b-I), the boards' platform items: the hardware watchdog is
  armed and reloaded by the root's watchdog thread on every boot, so only a hang
  before that thread starts (in the firmware or in Fiasco's boot) stays hung until
  the power is cycled; no crash region, no trial request and no device
  secret (M12). Development
  builds run trusted code only until M11.
* [Medium] Fiasco backend, a device's input and a fault's reach on Fiasco (R1's published downsides; erXos's
  kernel closes them). What holds: an interrupt whose pin was unbound after another CPU acknowledged it
  is ended at its chip, not dereferenced (`Irq_chip::handle_irq`, `fiasco/kernel/src/kern/irq_chip.cpp`);
  an SError taken in user mode ends the task of the thread that ran with a fault record of kind
  `async_error` (`arm_serror_user_entry`, `fiasco/kernel/src/kern/arm/thread-arm.cpp`, decided by
  `liberx/backend/fiasco/arch/aarch64/exception.c`). What does not:
  * attribution beyond the running thread: Fiasco's kernel runs with SErrors masked, so an SError
    is taken at the next entry to user mode on its CPU and presumed that thread's, and a device
    error raised while a domain was in the kernel, or by a posted write, can end another domain's
    task (K12's limit). Where it lands in the root, the root's main and runtime threads end the
    machine (`service_fault`), its service and watchdog threads, whose exception handler is sigma0,
    resume with nothing recorded (sigma0 refuses the message), and in sigma0 it is only counted; Fiasco has no exit window and reads no severity or error
    records, so an uncontainable error is not stopped either. No test provokes an SError, since QEMU
    `virt` raises none a guest can cause: only the root's decision is tested
    (`test/host/fiasco_exception_test.rb`);
  * every SError is counted per CPU (`num_serrors`, which jdb shows), but no log line names one and
    the inspector has no attribute for the count;
  * a pin read on one CPU while another detaches it (`Irq_chip_gen::detach`) reaches a handler whose
    object is already bound to the software chip, whose acknowledge does nothing, so that CPU's
    interrupt is never ended: every GIC priority is the same, so that CPU takes no more timer ticks,
    IPIs or device interrupts, a silent hang reached by a driver domain ending while its line fires on
    another CPU. Only `handle_irq` knows which chip acknowledged the interrupt, so no small fix
    exists; and `Icu_h::op_icu_unbind`
    (`fiasco/kernel/src/kern/icu_helper.cpp`) detaches without the IRQ's lock that
    `Irq_chip::detach` requires;
  * a wedged bus, which stalls the CPU that touches it with no fault to end anything;
  * DMA of unconfined devices (the item above, FD12);
  * on the Raspberry Pi 4, a hang before the root's watchdog thread starts (in the firmware or in
    Fiasco's boot) stays hung until the power is cycled, since the PM watchdog is armed only by that
    thread (the item above, FD29).
* [Low] liberx Fiasco backend, `erx_fiasco_exception_kind`
  (`liberx/backend/fiasco/arch/aarch64/exception.c`): the exception class's position and the SError
  class are written by hand, since `tools/erx sysreg refresh` refuses ESR_EL1, whose ISS layout
  depends on EC; let the refresh keep the fields that do not (EC, IL) and generate them. The same
  function reports alignment and breakpoint exceptions as `undefined`, though the ABI has both kinds.
* [High] DMA platform evidence: the SMMUv3 specification and QEMU
  v11.1.2 source audit is recorded in
  [research-hardware-contracts.md](research-hardware-contracts.md).
  Close each platform's outstanding evidence gate for SMMU queue
  quiescence and drain, valid-abort and ATS rejection, completed
  invalidation visibility, failed-reset handling and stale-event
  retirement. Source inspection is not executable conformance evidence.
  Keep unknown SMMU handoffs and completions closed, a confined device's
  memory held until its window's invalidation completes and an
  unconfined device's for the boot, until the exact supported platform
  meets the contract ([design-platforms.md](design-platforms.md),
  [plan.md](plan.md#m11-security-closure)).
* [Low] Fiasco backend, `erx_info` of `ERX_INFO_BUDGET` (`liberx/backend/fiasco/service.c`, `service_info`):
  any task asking about its own budget is answered with the page pool's machine-wide used count
  (`erx_fiasco_vm_used_pages`), so every domain learns how much memory all the others hold. The design reports a
  budget's own `used` from its record ([design-fiasco.md](design-fiasco.md#reporting-a-budget)); until
  records count pages, the field is reported unsupported rather than as the pool's count.


## Planned features

* [Medium] Fiasco, release builds (design-fiasco.md, "Boot handoff", the kernel): a
  release kernel is configured without JDB and the kernel's console input, so a panic reboots
  instead of waiting on the console (`tools/erx build release-kernel`, `FiascoConfig::RELEASE_UNSET`),
  but no image packs it: every image is a development build (`ProductionImage::BUILD_KIND`);
  the release image build must take `Fiasco#build_release_kernel`'s kernel and extend the
  provenance audit (`fiasco_provenance.rb`, which reads `build/fiasco/kernel`) and the build
  memo to it. A panic before `Psci::init` and `Dt::init` in `Startup::stage2`, the handoff
  checks of `erx_handoff.cpp` among them, finds no reset method and loops forever
  (`reset-arm-gen.cpp`). The kernel picks the PSCI conduit at run time from the device tree
  (`CONFIG_ARM_PSCI_DYN`; QEMU virt says hvc, the Pi 4 SMC through BL31), and the device tree
  is readable only after `Kip_init`, while the banner's handoff check runs in stage1. The fix
  is to run `Kip_init` and `Dt::init` ahead of `Kmem_alloc::init` in stage2, fold the banner
  and `check_descriptors` into one handoff step right after `Dt::init`, and have
  `platform_reset` run Psci's own probe (without the ACPI fallback) when PSCI is not yet
  detected; Fiasco's own stage1 and `Kip_init` panics stay a residual. The test boots a
  release image whose handoff record is refused. The reboot rests on reading `kernel_panic.cc`, `thread.cpp`,
  `terminate.cpp` and `reset-arm-gen.cpp` and on the configuration check; no release kernel
  has panicked under QEMU. The test that settles it boots a release image whose kernel panics
  after `Psci::init` with `-no-reboot` and expects QEMU to exit after the panic line, and one
  whose handoff fails, once the early reset is fixed. Still in a release kernel and each a
  question for the release: `CONFIG_RT_DBG`, which adds object naming and the kernel memory
  statistics dump to the console (`jdb_kobject`, `CONFIG_JDB_KMEM_STATS`) to the debugger
  kernel object `jdb_object`, which only a kernel with the debugger compiles; and
  `CONFIG_PERF_CNT_USER`, user-mode access to the performance counters, which Fiasco's Kconfig
  marks for debugging only.
* [Low] Fiasco, published images (`config/fiasco/kernel.defconfig`, `tools/lib/erx/fiasco_config.rb`,
  `LicenseCheck::TABLE`): 0.1's published images carry the development kernel, with JDB, the kernel's
  console input and `jdb_object.cpp` (GPL-2.0-only), by decision. Once published images should drop it, a
  developer-only debugger kernel: a switch that builds a kernel with the debugger for a developer's own image,
  which the published build refuses, the published kernel built without it, and the closed table's
  `jdb_object.cpp` row deleted. Until then anyone at the console of a published image's panicked machine
  reaches the debugger, which reads and writes kernel memory: on the Pi 4 until the watchdog resets the
  board, on QEMU and the browser demo without limit.
* [Medium] Fiasco backend, root task, `liberx/backend/fiasco/rng200.c` and every device read of the root: a device read
  that never completes stops the root silently. On QEMU's `raspi4b` model the first read of the RNG200's CTRL
  never returned, while the mini UART's page, mapped the same way at the same point, read; the root stopped before
  its entropy line, with nothing on the console to say where, and the `raspi4b` suite timed out at
  `release-slogan`. The model's tree disables the RNG200's node (`unmodelled` in `tools/lib/erx/board_tree.rb`),
  so the root does not read there, but a board whose device does not answer would stop the same way. A
  cheap diagnostic is a console line before the root's first read of a device it maps itself, so the last line
  names the device.
* [Low] Fiasco backend, root task, `liberx/backend/fiasco/rng200.c` `erx_fiasco_rng200_read`: a FIFO_COUNT read that
  fails inside the loop returns at once, past the erase of the local `word`, so the last secret word taken stays
  in the stack frame. The fix routes that failure through the one erase and return.
* [Medium] hosted backend, `liberx/backend/hosted/` ([design-fiasco.md](design-fiasco.md#the-hosted-backend),
  [plan.md](plan.md#track-h-hosted-mode)): the multi-process form, in which each space other than the
  first is a macOS process, so domains, connections and sessions run under the sanitizers and E-D1 can be
  measured between hosted domains. It is deferred until a consumer needs the sanitizers or `lldb` across
  domains (the Bluetooth suites, its first candidate, run on QEMU `virt` over a virtio-console line); until
  then the hosted backend is one process with the rows 1b-A needs where they are cheap. Its design is
  written and reviewed before its code. Check which hosted suites the other designs name need it (the display
  suite under ThreadSanitizer, design-display.md G2; the WiFi domain in hosted mode, design-wifi.md and plan.md
  Track W): each either moves to QEMU or waits for this form.

* [Low] upstream OTP, `erlc` (stock OTP 29.1.2, the oracle's): run from a directory whose
  path is a string prefix of a source's absolute path without being its parent, it strips
  that prefix and fails: from `/Users/stas/erxos`, `erlc -o /tmp/x
  /Users/stas/erxos-scratch/a.erl` reports `-scratch/a.erl: no such file or directory`. The
  prefix test is `shorten_filename/1` in `otp/lib/compiler/src/compile.erl`: it keeps the rest
  of the name when that rest does not start with `/`, where it should keep the whole name. Fix
  it in the tree's copy with a test, and report it upstream.
* [Low] upstream OTP, `otp/erts/emulator/beam/bif.c` (`list_to_ref_1`): report to OTP that in
  stock OTP 29.1.2 `list_to_ref/1` of a text whose six numbers each end in `.` (`"#Ref<4.1.2.3.4.5.>"`) leaves its
  parse loop with `i` at 6, so the copy into `refn` reads `ints[6]` past its six entries and writes `refn[5]` past
  its five: a stack overflow on any text a caller passes. erXos's copy refuses it with `badarg`. Send it with a
  reproduction run against stock OTP.
* [Low] upstream OTP, `otp/lib/kernel/src/inet_dns.erl` (`decode_data/3`): report to OTP that in stock OTP 29.1.2 a DNS reply carrying a record of type UINFO, UID, GID or UNSPEC (100 to
  103), IXFR, AXFR, MAILB, MAILA or ANY (251 to 255), or an A, AAAA or WKS record of a class other than IN,
  fails `inet_dns:decode/1` with `function_clause`, since those types map to atoms that no clause of
  `decode_data/3` names and its last clause takes only an integer type; `inet_res`'s `decode_reply` does not
  catch it, so a forged reply crashes the resolver's caller. erXos keeps their data raw (edit 62);
  `test/erlang/erx_net_resolver_fuzz.erl`'s `dns` target found it. Send it with a reproduction run against
  stock OTP.
