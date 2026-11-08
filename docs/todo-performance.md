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

* **[Medium] display, a layout change in `erx_screen`.** `erx_screen_core:layout/2`
  (`erlang/apps/erx_display/src/erx_screen_core.erl`) tiles and compares in O(L^2 log L) for L
  window and decoration rectangles, and every flush waits behind it. Measure a layout change of
  a 64-window rio layout and of a weave on QEMU `virt` under HVF and TCG once `erx_screen` exists;
  the fixes (newest layout only, a rectangle cap) are in `TODO.md`'s security residual for G3.

* **[Low] kernel, a destroy's slot names.** `erx_cap_slot_name` (`kernel/core/cap.c`) finds a
  listed slot's index by scanning its table's directory, up to `ERX_CAPS_MAX / ERX_CAP_PAGE_SLOTS`
  page pointers per slot a teardown clears. Measure a destroy of an object named by many slots in
  a full table; if the scan shows, store each page's first index in its slots or align pages so
  the index follows from the address.

* **[Low] packer, fsimg on every build.** `ProductionImage#assemble`, every test image
  and the hosted `Release#build` write the system release's EROFS image (`ReleaseMedium.image`) with `fsimg cW`, which also verifies it, before
  packing, since the manifest records its extent; the hosted pack uses only its length. Measure the
  added wall time of a production and a hosted build; if it matters, size the image without writing it
  twice, or cache it by the release's digest.
* **[Low] liberx, `erx_etf_check` with accept on maps with many or large keys.** `liberx/erx_etf.c`
  hashes every leaf inside a map key with BLAKE3 and every container element with one more BLAKE3
  call, then heapsorts each map's key digests; a string key of n bytes costs 2n + 3 hashes. Measure
  bytes per second of the check with and without accept over maps of 10, 1,000 and 100,000 small
  keys and over keys that are long strings and deep tuples; if it matters, take a byte's digest from a
  table of 256, hash a key's bytes in one pass where its canonical form equals its encoding, or use a
  cheaper keyed hash.
* **[Medium] shell, the evaluator's heap per word of a list.** Under the 4 MiB heap limit the design
  gives every evaluator, `k=(); while(! ~ $#k 5000) k=($k x)` is killed while a thousand iterations
  fit (Homebrew's OTP 28 on macOS, `erx_shell_eval_tests`): each `k=($k x)` builds the whole list
  again through per-word chunk lists, and the dead copies promoted to the old heap count until a
  major collection. Measure peak `total_heap_size` against list length, and try a lower
  `fullsweep_after` for evaluator processes and a path that skips the chunk lists for words that
  come from values. Measure on the stock OTP 29.1.2 the gates use
  (`build/oracle/jit/install`), not only on Homebrew's.
* **[Medium] shell, `~` and `switch` on a long subject.** The evaluator's
  matcher turns the subject into a list of characters for every pattern, so
  under the 4 MiB evaluator heap `~ $x *b*` is killed on a 100 KB subject
  while 50 KB passes. Measure peak heap against subject length, and match
  over the binary with byte offsets and a pattern compiled once.
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
* **[Low] runtime, first-open hash of release files on the target.** `erx_prim_file.c`
  hashes each release file at its first open with BLAKE3's portable code, so a boot
  hashes every module it loads. Hosted, the cost is small; on the target it is
  unmeasured, since no native release boots yet. Settled by boot to `1>` with and
  without the check under TCG, HVF and on the Pi 4.
* **[Low] runtime, dirty-scheduler switches before a release path.** A relative path on the
  release asks `get_cwd_nif` and then `release_walk_nif`, both dirty IO, before the operation's
  own NIF, and `efile_path_t` is about 4 KiB on the C stack, two for a rename or link. Measure
  `file:read_file_info/1` on a relative release path against an absolute one with
  `tools/erx bench`, and check the dirty-IO thread stack size.
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
* **[Low] storage, the Pi 4 has no SHA-256 instructions.** `erx_verity`
  checks EROFS blocks with SHA-256 in dm-verity's tree format, and the Pi 4's
  Cortex-A72 lacks the Arm SHA-2 extension, so each block hashes in plain C.
  Settled by `tools/erx bench fs` on the Pi 4, which decides whether BLAKE3,
  already in the tree, is worth giving up dm-verity's tree format.
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

* **The production image's `NOTICES` and Fiasco's audit** (`tools/lib/erx/production_image.rb`, Phase 1 stopgap): `NOTICES` is 0.8 MiB of the 23.6 MiB development boot image `tools/erx boot` builds, with each licence text once, never released and touched page by page at boot, and one pack spends about 5 minutes re-auditing Fiasco on a loaded host. Measure: the root's boot time with and without those pages, and the audit's time on an idle host.

* [Low] `liberx/backend/core/handles.c`, `liberx/backend/fiasco/object.c`: a create scans the object records and the caller's handle table from the start for the lowest free one, and a task's end scans every record, so n creates in one table cost O(n^2), and the root's table may reach 262,144 entries. Settled by the time of 10,000 creates and closes in the root, and of a task's end with 10,000 objects.
* [Low] `liberx/backend/hosted/vm.c`, `liberx/backend/core/vm_table.c`: each hosted start clears the range table's 64 MiB index, sized from the 8 GiB pool, though a fresh `mmap` is already zero. Settled by a boot time with and without the clear.
* [Low] `otp/erts/emulator/sys/erxos/erx_event.c`, `beam/erl_process.c`: a wake through the ready list against stock's poll
  thread and scheduler wake. `tools/erx bench` runs the oracle alone and has no hosted workload, and only `prim_tty`'s reader
  fires a label today. Settled by a bench of an IRQ object's trigger to a process sink's receive, hosted against stock's
  `enif_select` on a pipe, once the pipe NIF or the device NIF gives it a consumer.
* [Low] `otp/erts/emulator/sys/erxos/erx_event.c`: `deliver` allocates one short-lived environment per delivery to a process
  sink, on top of the message. Settled by the same bench at an interrupt rate a driver sees, with and without one environment
  kept per entry.
* **`/tmp`'s hops per operation** (`erx_ramfs`, [design-tmp.md](design-tmp.md#where-tmp-runs)): a `/tmp`
  operation is two or three local message round trips (the grant, the file's owner for an open file's reads and writes,
  then the tree process; `erx_ramfs`'s reads run in the owner, with no helper), plus the NIF's resolve for a path operation, where a C provider in the NIF would cost one move to a dirty
  scheduler; a Common Test run writes its logs a line at a time. Measure, each number against another from the same
  runtime under the same accelerator: 10,000 line-sized `file:write/2` calls and 1,000 `file:read_file_info/1` and
  `file:read_file/1` calls of 4 KiB files on `/tmp`, against the same reads on the release file system, which the NIF
  serves, and against `erx_ramfs_core:step/4` run alone on the same tree, so the difference is the dispatch; and the
  same workload in the hosted runtime against stock OTP 29.1.2 on the same host, both native, for the end-to-end cost.
  Also record the tree process's memory against `held` after the workload, which [Charges](design-tmp.md#data-model)
  leaves unpromised. Fixes on the table, cheapest first: the grant calling the tree directly for a file with one open; shape (b) of the design, the same core
  reached by one round trip.
* **[Low] files, reading an EROFS image without a cache** (`erx_erofs` and
  `erx_verity`, [design-storage.md](design-storage.md#reading-erofs-images)):
  every operation reads its names' inode and directory blocks through the
  funnel again, and the superblock's CRC-32C runs bit by bit in Erlang at each
  mount. An open file of an image (`erx_erofs_file`) walks its names again for
  every read, and `erx_verity` sends the window one request per 4 KiB block,
  since a window request carries at most 8 sectors, all sent before the first
  answer. Settled by operations a second over a release image on the host's
  stock OTP with and without the design's metadata cache; the fix on the table
  is that cache, and an open file keeping its inode.
* **[Low] files, resolving a path in Erlang** (`erx_path`, [design-files.md](design-files.md#resolving-a-path)):
  each run the resolver places is list work over up to 256 names and 64 entries in the calling process; a `.` or `..`
  after a name the path has not yet walked costs a walk of its own, one round trip more, and on the release file
  system one `release_walk_nif` call more; and a link costs two round trips, the walk that stops at it and the read of
  it. Measure, hosted, against stock OTP 29.1.2 on the same host: 1,000 `file:read_file_info/1` calls each of
  `/tmp/a/b/c`, `/tmp/a/x/../b/c` and a path through one link, and of the same three on the release file system, each
  with a table of 4 and of 64 entries, so the release's numbers show the resolver's own cost with no round trip to hide
  it. Fixes on the table, cheapest first: keeping the table sorted by point length so placing stops at the first
  match; sending a `..` that follows a new name in the same walk, which the grant answers from its fid's record of the
  directories it came through, for walks that stay below the entry's `root` (design-files.md's Alternatives weighs it).
  Every run retraces the place from the entry's top, so the names walked grow as runs times depth: a 4 KiB path of
  255 names and then some 700 repeats of `/b/..`, with 32 link texts of the same shape, walks millions of names where
  FreeBSD looks up tens of thousands. Measure that path's walk count and time; the fix is a walk from the fid the
  last walk reached when the place only grew.
* **A grant's step count over a whole fid path** (`erx_fs_grant:repath/3`, [design-files.md](design-files.md#serving-the-erx_fs-behaviour)): every new fid, walk in place and clunk counts or uncounts each step of the fid's path, so a clone of a fid at depth D costs D map updates where it cost none, and an end of a grant's owner costs the sum of its fids' depths. Measure: a clone and a clunk of fids at depths 1, 16 and 256 under `tools/erx bench`, against the same with only the steps that differ between the old and new paths counted.
* **[Low] files, a scan of every process per namespace change** (`erx_ns`,
  [design-files.md](design-files.md#building-binding-and-mounting)): the table is a persistent term, so each `mount`,
  `bind` and `unmount` replaces it. In OTP 29.1.2 a replaced value goes on a delete queue
  (`otp/erts/emulator/beam/erl_bif_persistent.c:1189-1203`, `table_updater`), and `delete_tuple` (:1293-1300) frees
  it at once only when it is an immediate; any other, such as the table, goes to `erts_queue_release_literals`, and
  the literal area collector then asks every process of the runtime to look for it in its heap and copy what it
  finds (`beam_bif_load.c:1466-1490`). Putting an equal value changes nothing (`erl_bif_persistent.c:726-729`). The
  working directory is kept out of a persistent term for this reason. Measure, hosted: the time of 1,000
  `erx_ns:bind/2` and `erx_ns:unmount/1` pairs with 100 and with 10,000 idle processes of 1 MiB heaps each, and a
  domain's start-up with its usual mounts against the same start with none. Fix on the table: batching a domain's
  start-up mounts into one put.
* **Runner's poll for a child's exit** (`tools/lib/erx/runner.rb`, host tooling): `run` checks for exit every 50 ms, so a short child costs up to that much more, and one pack starts about 450 children. Measure: a pack's time with a poll that starts at 1 ms and backs off to 50 ms.

* **The PL011 console driver sends a byte at a time** (`erlang/apps/erx_uart/src/erx_pl011.erl`, `send`): each byte costs two register BIF calls, a read of `FR.TXFF` and a write of `DR`, and a full transmit FIFO waits a whole millisecond before it looks again. The command shell's `cat` of `/NOTICES` reached the host's terminal at about 256 KB/s (769,610 bytes in 3 s; Apple M3 Max, macOS, HVF, QEMU 11.1.3, one guest CPU, the development boot image of `tools/erx boot`, the serial line on a pseudo-terminal), so a 16 MB file takes about a minute. Settled by timing the console transcript's 20,000-byte output under HVF against a send that waits for `FR.TXFE` and then writes a whole FIFO's worth without reading `FR` between bytes.

* **[Medium] display, a full-screen pixel load across domains**
  ([design-display.md](design-display.md#performance)): a `y` load crosses
  the lane, the funnel, the file server and `erx_memdraw`. Settled by
  MB/s on HVF at 1920x1080; the fix on the table is a pixel object made by
  the system domain and installed in both domains, as shared mappings are.
* **[Low] display, the copy from the screen image to the framebuffer pool**
  per dirty rectangle (`erx_device:fill/3`). Settled by frame times on a
  full-screen redraw; the fix on the table is an `erx_memdraw` image over
  the pool buffer.
* **[Low] display, the dirty-scheduler threshold for draw operations**
  (64 KiB of destination pixels proposed). Settled by latency of small and
  large draws on and off dirty schedulers.
* **[Medium] display, the Erlang renderer's frame on a 240x240 panel**
  (diff, layout and draw) against LVGL's. This is LVGL's retirement gate.
* **[Low] display, the terminal emulator's redraw per changed cell line.**
  Settled by scrolling throughput of a large output, redrawing scrolled
  rows against copying their pixels.
* **[Medium] display, `erx_vt` parses a code point at a time in Erlang**
  ([design-display.md](design-display.md#the-terminal-emulator)). Settled
  by bytes per second over a large `cat` of plain text, of text with SGR
  on every word and of wide characters, against libvterm on the same
  corpus.
* **[Low] display, virtio-gpu transfer and flush latency per rectangle**
  under TCG, and how `erx_screen` gathers waiting flushes into one push. Settled by flushes per
  second and latency per rectangle size.
* **[Medium] display, a terminal's draws cross domains**
  ([design-display.md](design-display.md#performance)): `erx_term` runs in
  the session and sends every draw batch across the lane, the funnel and
  the file server. Settled by the scrolling of a large `cat` at 80x24 and
  at full screen on HVF; the fix on the table is the pixel object above.
* **[Low] display, the display domain's own clients go through `erx_winfs`**
  ([design-display.md](design-display.md#performance)): the menu and the
  Erlang renderer send every draw batch through the file server. Settled
  by renderer frame times against a direct hand-off.
* **[Low] display, composes run one at a time in `erx_screen`**, and a
  window waits in its flush call. Settled by several animating windows and
  a kiosk's flush latency.
* **[Low] display, a kiosk under LVGL copies each dirty rectangle twice**
  ([design-display.md](design-display.md#kiosks-and-glasses)): once through
  the LVGL program's standard output into the display domain, once into
  the framebuffer. Settled by a full-screen redraw's time on a 240 by 240
  panel and at QEMU `virt`'s screen size under HVF; the fix on the table
  is the scan-out buffer mapped into the program's sub-space, which
  design-display rejects until a number asks for it.
* **[Medium] web, a record view's round trip over the host tool's front end**
  ([design-web.md](design-web.md#performance)): each update crosses the host
  link, the system domain's relay, the web domain, the session's line and the
  inspector, and a record view sends whole records every 2 s while they change.
  Settled by round-trip times and link bytes per second for the machine's
  record and a 1,000-child listing, under HVF and over a 115,200-baud
  UART; the fix on the table is a record difference message.
* **[Low] web, `erx_ui_model:pair/3`, `delta/2` and `erx_ui_schema` for a
  1,000-node tree,** and a tree's first attachment, which arrives over several 64 KiB
  updates. Settled by time per call on HVF and the attachment's time over the
  UART host link; the fix on the table is keeping the delta from the server's
  operations instead of comparing models.
* **[Low] display, decoding a widget's PNG image in the Erlang renderer**
  ([design-display.md](design-display.md#widget-trees)): an `image` node's
  48 KiB of PNG is inflated and unfiltered before its pixels are loaded with
  `y`. Settled by time per decode of a 48 KiB image on HVF and on the
  Raspberry Pi 4; the fix on the table is unfiltering in C beside
  `erx_memdraw`, as a per-byte primitive.
* **[Low] web, the client's first load and the bundle's size,** over the host
  tool and over the network front end. Settled by bytes served and time to the
  first rendered view; the fix on the table is splitting the bundle by route.
* **[Low] shell, a process per parsed unit.** The evaluator parses each unit
  of source, rc's line, through `erx_shell_parse:next_bounded/3`, which spawns
  a child with a fixed 8 MiB heap and copies the unit's tree back as its exit
  reason ([design-shell.md](design-shell.md#the-language)). Nothing has
  measured the spawn and the copy against the parse itself, for a script of
  many short lines and for a unit at the 4 KiB bound. Measure: a `tools/erx
  bench` workload running a script of 10,000 one-command lines and one of
  4 KiB units, through `next_bounded/3` and through `next/2` called directly,
  with a mailbox of pending stage messages: the receive of the child's
  `'DOWN'` gets no receive marker, so it scans the whole mailbox.
  Fixes on the table: parsing a run of short units in one child, or parsing a
  unit in the evaluator itself when its window is small enough that its worst
  heap fits the evaluator's spare heap.

* **The block driver's request geometry.** `erx_blk` posts three segments per request (header, sectors, status), so its
  16-descriptor queue holds at most five requests while the pool reserves sixteen 4113-byte buffers, and the odd stride
  lets buffers share cache lines. Two segments (header and sectors out or in, then the status) and a buffer size rounded
  to a cache line would double the requests in flight; settle it with `tools/erx bench` read throughput under HVF.
* **One request in flight per window.** `erx_blk_window` answers one request at a time and waits on `erx_blk` for each,
  so a file system on one window has one request at the device while the queue holds several. Settled by
  `tools/erx bench` read throughput under HVF through one window against several clients of the device process.

* **[Low] per-byte primitives, `erx_bytes:crc32c/2` runs the portable code only.** It
  takes four bits per table step, two steps a byte, and does not use the CPU's CRC-32C
  instructions that [the design](design-runtime.md#per-byte-primitives) puts behind the
  architecture layer. Measure: a `tools/erx bench fs` read of an EROFS image that checks
  its superblock and blocks, on HVF, against the same read with the call stubbed to a
  constant. Fixes on the table: a byte-at-a-time table of 256 entries, slicing by eight,
  then the AArch64 instructions chosen by feature detection in the architecture layer,
  the portable code staying as their oracle in the same test.
* **[Low] per-byte primitives, `erx_bytes:sha256/1` runs FreeBSD's portable C only.**
  It does not use the CPU's SHA-256 instructions (AArch64's FEAT_SHA256) that
  [the design](design-runtime.md#per-byte-primitives) puts behind the architecture
  layer; the portable code took about 240 microseconds over 64 KiB in a one-off loop
  on the development host (Apple M-series, macOS, native, clang -O2, 2026-11-06), not
  a benchmark. Measure: the time the code server spends checking blobs during a boot
  that loads every module by hash (`tools/erx bench` of that boot, on HVF), against
  the same boot with the check stubbed to the expected digest. If the check is a
  visible share of the boot, add the instructions, chosen by feature detection in the
  architecture layer, with the portable code as their oracle in the same test. The
  same run should time one 64 KiB call on each target board, since `erx_bytes_nif.c`
  charges it a quarter of a reduction slice from the host's number.
* **[Low] per-byte primitives, `erx_bytes:inet_csum/2` and `siphash24/2` run portable C
  only.** The checksum adds one 16-bit word at a time into 64 bits and does not use the
  CPU's checksum-friendly instructions that
  [the network design](design-network-stack.md#where-c-is-used-and-what-is-measured)
  puts behind the architecture layer. In a one-off loop on the development host (Apple
  M3 Max, macOS, native, clang 23.1.3 -O2, 2026-11-08), not a benchmark, a 64 KiB call
  took about 16 microseconds for the checksum and 110 for SipHash-2-4, and a 36-byte
  SipHash (a SYN cookie's input) about 60 nanoseconds; `erx_bytes_nif.c` charges 2 and
  11 percent of a reduction slice from these. A small call also pays the wrappers'
  `iolist_size/1` and `erlang:iolist_to_iovec/1` when given a list. Measure: the time
  per frame of the bulk-transfer load the network design names, on HVF, against the
  same load with the checksum stubbed; and one 64 KiB call of each on each target
  board. If the checksum is a visible share, add a wider portable loop (32-bit loads,
  deferred carries) and then the AArch64 instructions chosen by feature detection, the
  portable code staying as their oracle.
* [Low] `erlang/apps/erx_shell/src/erx_shell.erl`, `end_line/3`: every unit the command shell runs, a refused one included, ends with at least one pass over `erlang:processes()` with a `process_info/2` per process, so its cost grows with the system domain's process table. Settled by the time of an empty line's unit at the console with the domain's usual process count and with ten times as many.
* [Low] `tools/lib/erx/generated.rb`, `Erx::Generated.require_ruby`: every Ruby process that loads a generated Ruby file (each `tools/erx` call, each host test process using the ABI or terminal tables) loads the generator libraries and hashes every `tools/lib` file and every input and output to check the stamp, about 80 ms over loading the file alone when the tree is fresh (a reviewer's rough number on Apple Silicon macOS, not a recorded measurement). Settled by the wall time of `make check` and of `ruby tools/erx status` with and without the freshness check; if it shows, check a cheap digest of the stamp's inputs before loading the generators.
* **[Medium] network, a round trip per `gen_tcp:send/2` across a lane**
  ([design-network-stack.md](design-network-stack.md#the-backend)). Each
  send waits for the connection's reply that the data is in its send
  buffer. Settled by bulk throughput with 1 KiB and 64 KiB sends against
  line rate; the fix on the table is asynchronous sends against a byte
  credit, which needs a client-side process per sender.
* **[Low] network, one message per in-order segment against coalescing**
  ([design-network-stack.md](design-network-stack.md#hops-and-copies)).
  A connection delivers each step's in-order data in one message; joining
  several segments' payloads into one binary saves messages and lane
  frames at the cost of a copy. Settled by a bulk receive's CPU time per
  byte both ways.
* **[Low] network, ETS reads on every output pass**
  ([design-network-stack.md](design-network-stack.md#transmitting)). A
  connection reads its neighbour entry and the route table's generation
  from ETS each time it outputs. Settled by the time per frame of a bulk
  send with and without caching them across a step's frames.
* **[Medium] network, one interface process per interface as a ceiling**
  ([design-network-stack.md](design-network-stack.md#residuals)). Every
  frame of an interface is decoded in one process, the bound on its frame
  rate for every client. Settled by the minimum-size frame rate one
  interface process keeps up with, on erXos's kernel and on the Pi 4; the
  fix on the table is one interface process per receive queue.
* **[Low] network, a hibernated TIME-WAIT process**
  ([design-network-stack.md](design-network-stack.md#time-wait)). Each
  connection in TIME-WAIT is a process for 60 s. Settled by the memory of
  4,096 of them against FreeBSD's control blocks in the same state.
* **[Low] network, credits and per-step reduction accounting**
  ([design-network-stack.md](design-network-stack.md#credited-queues)).
  Each hand-over costs an `atomics:add_get/3` and each socket step two
  `process_info/2` reads and an `atomics:add/3`. Settled by the time per
  frame of a bulk transfer with both and with a build that leaves them out.

* The syntax-tree chokepoint pass (`tools/lib/erx/syntax_tree.rb`, run by
  `StackProofRun`): it dumps every core's tree, 20-27 MB of JSON each,
  in sequence, which a review measured at about 28 s on an Apple Silicon
  host, once in `make check` and again in every Fiasco kernel build.
  Settle it by timing `make check-stack-proof` with and without the
  pass; if it matters, run the dumps in parallel or cache them by the
  tree's hash.
