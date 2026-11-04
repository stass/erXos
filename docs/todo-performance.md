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
* **[Low] stopgap, machine-wide lists.** The stopgap's budget funnel keeps
  one machine-wide released list, and its RCU keeps one grace list
  ([design-stopgap.md](design-stopgap.md)), each behind one lock. With many
  CPUs releasing pages or retiring records at once they may contend.
  Measure lock hold and wait times under a page-churn workload at 4 CPUs
  before G1's numbers are taken; per-CPU lists belong to erXos's own kernel
  if the contention is real.
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

* [Low] stopgap, the system-call case of `Thread::arm_esr_entry`: every
  Fiasco system call also pays one out-of-line `Erx_syscall::is_call`, and
  an erXos call a frame copy and the admission's calls, with interrupts masked
  for the whole call, its console write included. No `tools/erx bench`
  workload covers kernel entry on the stopgap: the `null` workload named
  above is the one to measure them with. Fixes: compare the immediate in
  place, and drain the console after unmasking interrupts.
