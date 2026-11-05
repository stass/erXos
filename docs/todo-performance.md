# Performance watch list

Places where erXos may be slow, written down so they are measured before
they are forgotten. Each item names the cost, where it sits, the
measurement that settles it (a `tools/erx bench` workload, existing or to
be written) and the fixes on the table. An item is a suspicion, not a
finding: no item here changes a design until a measurement says so.

When a measurement is taken, record its result where
[CLAUDE.md](../CLAUDE.md) requires (host, accelerator, QEMU version,
compiler, flags, workload, baseline) and remove the item: either the cost
is acceptable, or the fix becomes a design change and a `TODO.md` or
roadmap item. Latency and fairness that a stopgap does not promise are
residuals of the component that replaces it, not items here, unless they
block a milestone's numbers.

* **[Low] drivers, the cost of a register access from Erlang.** `erx_device:read/2`
  and `write/3` are BIFs, each resolving a register's name and checking it in
  the generated table. Nothing has measured that against the access itself, a
  VM exit under HVF and an uncached load on hardware, or against the wake from an
  interrupt to the driver's process. Measure: a `tools/erx bench` workload of register
  reads, on HVF and then on a Raspberry Pi, split into the call, the name lookup, the
  access and the wake. Fixes on the table, cheapest first, all behind the same
  `erx_device` interface: a call that takes a batch of accesses in one crossing;
  resolving the name at the driver's start so an access takes an index; a
  loader-specialised instruction in the interpreter and the BeamAsm image that
  performs the access inline.
* **`read_file` copies from the release's pages.** `erx_prim_file.c` serves `prim_file:read_file/1` through
  stock's `read_file` in `prim_file_nif.c`, which allocates a binary and fills it, where the design allows a
  binary over the slice's pages. Settled by timing a boot that loads every module of `kernel` and `stdlib`
  from an archive, with and without the copy.

* **[Low] Fiasco backend, the cost of a commit in the root.** Each committed
  page zeroes through `root_mem.c`'s word loop and makes one `l4_task_map` call.
  Settled by a `tools/erx bench` workload of committing and touching a large
  range on HVF; the fixes on the table are musl's `bzero` and mapping runs of
  contiguous window pages in one call.
* **[Medium] scheduler, the cost of one machine-wide scheduling lock.** The
  fallback to the cross-CPU protocol of
  [design-scheduler.md](design-scheduler.md#concurrency) serialises every
  context switch and wake on the machine through one lock held across the
stack switch. The estimate, unmeasured on any host, is a hold of 100 to 200 ns
per switch against an IPC call round trip estimated at 150 to 250 ns
([design-kernel.md](design-kernel.md)), so on four CPUs the lock may dominate
IPC-heavy work. Measure: a contended ticket lock across a switch, on four vCPUs
under HVF, with the `tools/erx bench` IPC workloads, against M7's gate, if
the protocol fails its model or its implementation. Fix: none is needed while
the protocol stands; if the numbers miss the gate, the lock is not taken.
* **[Low] stopgap boot, hashing with the MMU off.** `bootstrap` hashes the index
  and the files it places with BLAKE3's portable code before the MMU is on, so
  with the data cache off under HVF and native. The harness reads the serial log
  about every 50 ms, too coarsely to see this cost on a 1 MiB image. Measure: the
  time from `bootstrap`'s first line to the kernel's banner with serial
  timestamps, on HVF and the Pi 4, with a boot image of the size the first real
  system has. Fix on the table: turn the caches on before hashing.
* **[Medium] kernel, first-use hash of large boot image files.** The kernel
  checks each boot image file's BLAKE3 hash the first time it is mapped or
  read, once per file per boot, and runs BLAKE3's portable code because it
  executes no FP or SIMD instruction (K10 in
  [design-kernel.md](design-kernel.md)). NEON is several times faster on
  large inputs; neither has been measured on our targets. Small files (the
  stopgap's kernel, the root task) are unaffected; a large file mapped on
  demand, such as ML weights, pays the full portable cost on its first map.
  Measure: hash throughput, portable against NEON, on QEMU `virt` (HVF) and
  the Pi 4, and the first-map latency of a large image file, once boot image
  format version 2 lands. Fixes: one bracketed kernel routine that saves the
  current thread's FP state, hashes with NEON and restores it, as the only
  exception to K10's scan; or checking the largest files in `bootstrap`,
  which may use NEON.
* **[Low] host tools, the packer hashes with BLAKE3's portable code.**
  `tools/host/pack_hash.c` builds the only BLAKE3 in the tree, its portable
  C ([origin](../kernel/crypto/blake3/ORIGIN.md)), though
  [design-build.md](design-build.md) gives the host tools the SIMD paths,
  which are not imported. The packer also reads the whole archive into
  memory to hash it, and each of its three calls of the program rereads it.
  Packing a small image costs no measurable time; the cost at a full image
  of tens of MiB is unmeasured. Measure: `tools/erx pack`'s hashing time
  over a full image on the development host. Fixes: import the SIMD paths
  for the host build alone, and read only the runs asked for.
* **[Low] kernel, BLAKE3's round function out of line.** The imported
  BLAKE3 (`kernel/crypto/blake3/blake3_impl.h`) defines `INLINE` as plain
  `static inline`, not upstream's `always_inline`, because
  `always_inline` made a 5280-byte frame at -O0 that the stack proof
  refuses. At -O2 for the target, clang then keeps `round_fn` out of
  line: `erx_blake3_compress_in_place` calls it seven times per
  compression, with its state passed through memory. The throughput cost
  against the inlined form is unmeasured. Measure: portable BLAKE3
  throughput at -O2, `static inline` against `always_inline`, over the
  boot image's file sizes on QEMU `virt` (HVF), with the -O0 and -O2
  frames the stack proof reports for each. Fixes: `always_inline` at -O2
  alone, if the stack proof's -O0 build can keep plain `static inline`;
  or the seven rounds unrolled by hand in `erx_blake3_compress_in_place`.
* **[Medium] kernel, a walk of the group path at every decision.** The
  scheduler core (`kernel/sched/sched.c`) stores no derived limit, so each
  wake, each pick and each thread a pick examines loads the ceiling on every
  level of its group path, and again each cpuset, up to eight levels each,
  from group records that other CPUs' threads read too. A pick that examines
  a thread does this twice, for its urgency and for its CPUs. The cost is
  unmeasured. Measure: `tools/erx bench` park and wake on one and across
  CPUs at group depths 1, 4 and 8, on QEMU `virt` (HVF). Fixes: one walk per
  thread per decision that yields both limits, or a per-group generation
  that lets a thread keep its limits until an ancestor's grant changes.
* **[Low] kernel, a ready queue's size per CPU.** A CPU's ready queues are 64
  pairs of pointers beside the bitmap, a little over 1 KiB per CPU, and a
  pick reads two cache lines of them besides each thread's record. The cache
  cost against a smaller encoding, such as only as many levels as a machine
  uses, is unmeasured. Measure: context-switch latency against ready threads
  at one level and spread over all 64, on QEMU `virt` (HVF), with G1's
  numbers. Fixes: keep only the head and thread the tail through it, or
  compact the levels.
* **[Low] kernel, eager FP and SIMD switch.** Every switch saves and
  restores the full FP and SIMD state. Its cost is unmeasured; the
  `TODO.md` item on the eager switch's missing cases tracks the
  `tools/erx bench` workload that times it.
* **[Medium] stopgap, one service thread for every call.** In Phase 1 the
  root's one service thread serves every memory, thread and log call of
  every task and receives their faults
  ([design-stopgap.md](design-stopgap.md#helper-threads)), so the calls
  of all tasks queue on it. Of these `erx_irq_trigger` is the one to
  watch, since ERTS's scheduler wakes use it. Measure the service
  thread's queue depth and per-call time, and the wake latency of
  `erx_irq_trigger`, once ERTS boots. Fixes: serve the hot calls in the
  caller (a wake needs no root state) or add service threads; erXos's
  kernel serves these calls itself.
* **[Low] stopgap, the condition variable's extra wake.** The port always
  takes `unlock_requeue`'s branch that wakes the next waiter instead of
  requeueing it, and deletes `FUTEX_REQUEUE`
  ([design-stopgap.md](design-stopgap.md#thread-exit)), so a
  broadcast wakes each waiter once more than a requeue would. Measure a
  `pthread_cond_broadcast` over many waiters once ERTS boots; keep the
  wake unless it shows in ERTS's numbers.
* **[Low] kernel, a part of a range call goes through a tree split and join.**
  `erx_map_apply` (`kernel/core/map.c`) takes every edit out of the tree by two
  splits and puts it back by joins, up to about ten walks of a path of at most
  23 nodes, each rewriting a record of about 100 bytes, under the space's lock,
  where a boundary move inside one record needs only one walk up to refresh
  the summaries. A commit of 1 GiB runs this 4,096 times. Measure: `tools/erx
  bench mmap` with commits and protects over a space with many records. Fixes:
  an in-place path for a plan that keeps its records, behind the same plan.
* **[Low] kernel, admission as a step machine.** Every kernel call fills
  its admission plan (`erx_sys_admit_plan`, 16 bytes per position plus 8,
  for the positions of the ABI's largest call whatever this call's count)
  and makes one out-of-line call of `erx_sys_admit_next` per lookup, lock,
  run and release (`kernel/core/admit.c`), where an inlined, per-call
  admission would make none. On the null call, one lookup, that is three
  calls and a copy of the plan. Measure: the `null` workload of `tools/erx bench` once the
  dispatch loop lands, against the same call with the admission inlined.
  Fixes: let the dispatch loop and the core share a translation unit at
  -O2, or emit the per-call steps from the plan as straight-line code.

* **A task's exit over a large reservation** (`erx_backend_vm_table_clear`, Phase 1 backend): it probes the page index for every reserved page, committed or not, on the one service thread. Settled by timing a stop of a task holding a 1 GiB reservation under `tools/erx bench`.

* **ERTS's commits natively, one page at a time** (`liberx/backend/fiasco/vm.c`, Phase 1 backend). A hosted runtime has about 25,000 ABI pages (99 MiB) committed by `1>`, measured from `ERX_HOSTED_VM_RUNS` on macOS, Apple Silicon, 16 CPUs, Apple clang 21.0.0 at -O2, an interpreter build, one boot, no earlier baseline. Natively each page is taken, zeroed and mapped on the one service thread, whatever the guest then touches. Settled by timing a native boot to `1>` against its commit count, at 1 and 4 CPUs.

* **`erts_mremap` grows by copying** (`otp/erts/emulator/sys/common/erl_mmap.c`, `remap_move`). With no `mremap` on either target, a carrier that grows takes new pages and copies the old ones, where stock on Linux moves the mappings. Settled by counting `mseg_realloc` calls and their bytes in an allocation-heavy OTP suite natively.

* **Hosted commits take a host call per host page** (`liberx/backend/hosted/vm.c`, `host_refresh`). It sets one protection a page at a time, where a run could be one `mprotect`. A hosted ERTS allocator's commit may notice. Settled by timing a hosted boot's commits against a coalesced version.

* **A semaphore's wake path** (`fiasco/kernel/src/kern/semaphore.cpp`, `thread_state.cpp`, Phase 1 stopgap): an up holds one more state bit between its dequeue and its activation, and that bit has no before and after numbers. Settled by timing an up that wakes a blocked down, on one CPU and across CPUs, under HVF, on the kernel with the bit and without it.

* **The production image's `NOTICES` and Fiasco's audit** (`tools/lib/erx/production_image.rb`, Phase 1 stopgap): `NOTICES` is 12.6 MiB of a 13.6 MiB image, never released and touched page by page at boot, and one pack spends about 5 minutes re-auditing Fiasco on a loaded host. Measure: the root's boot time with and without those pages, and the audit's time on an idle host.

* [Low] `liberx/backend/hosted/vm.c`, `liberx/backend/core/vm_table.c`: each hosted start clears the range table's 64 MiB index, sized from the 8 GiB pool, though a fresh `mmap` is already zero. Settled by a boot time with and without the clear.
* [Low] `otp/erts/emulator/sys/erxos/erx_event.c`, `beam/erl_process.c`: a wake through the ready list against stock's poll
  thread and scheduler wake. `tools/erx bench` runs the oracle alone and has no hosted workload, and only `prim_tty`'s reader
  fires a label today. Settled by a bench of an IRQ object's trigger to a process sink's receive, hosted against stock's
  `enif_select` on a pipe, once the pipe NIF or the device NIF gives it a consumer.
* [Low] `otp/erts/emulator/sys/erxos/erx_event.c`: `deliver` allocates one short-lived environment per delivery to a process
  sink, on top of the message. Settled by the same bench at an interrupt rate a driver sees, with and without one environment
  kept per entry.
