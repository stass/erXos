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
