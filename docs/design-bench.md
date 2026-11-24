# Benchmarks: where erXos stands and when it slips

erXos has measured its runtime against stock OTP since gate G3, and nothing
below it: no number says how long a request to the root service takes, how
late a timed park returns, how a CPU is shared among spinning threads, or
what a page commit costs. The late interrupt of the Raspberry Pi 4's console
was found by chance, by a diagnostic probe written after bytes were lost
([design-fiasco.md, Urgency](design-fiasco.md#urgency), "The evidence").
This document designs the benchmark system: what a benchmark is, the one
clock every interval is read from, the record every run leaves in the
history repository, the rule that compares two records, the three limits
that fail a gate, the other systems erXos is measured against on the same
board, and the first five benchmarks.

Decisions every reader needs:

* **A result is a record, and the record says what it can be compared
  with.** Every run of `tools/erx bench` writes one record: a JSON manifest
  with each operation's status and summary, bounded histograms beside it,
  and the logs of its boots. The record separates where the run happened
  (the *environment*: machine, accelerator, CPU count, operating system)
  from what ran (the *subject*: source revision, image, compiler, flags,
  manifest). Two records are compared only when their environments are
  equal, so a TCG number is never set against a native one and no tool has
  to remember not to.
* **Every interval is two reads of one clock.** In a guest that clock is
  the architecture's system counter, which `erx_clock_ns`, ERTS's monotonic
  time and the trace ring's stamps all read; on the host it is the host's
  monotonic clock; at the Raspberry Pi 4's pins it is the logic analyser's
  sample clock. No interval is computed from two clocks, and one across
  CPUs is reported only with the bound calibration proved for it.
* **Thresholds are advisory, three excepted.** A comparison says `same`,
  `slower`, `faster` or `inconclusive`; inconclusive is never a pass. Once
  calibrated by three recorded runs, exactly three limits fail a gate: on
  the Raspberry Pi 4, every receipt of the console's line within 0.7 ms
  with no receive overrun, and every receipt of the SD controller's line
  within 1 ms; everywhere, no lost wake. A benchmark that sees its operation
  return a wrong answer fails as any test does; that is not a threshold.
  FD32's decision keeps the predicate [design-fiasco.md](design-fiasco.md#the-releases-fiasco-build)
  states for it, not this document's comparison.
* **Results live in the history repository, never in the tree.** The one
  record writer puts a run under
  `~/erxos-history/bench/<environment>/<run>/` and refuses a destination
  inside any worktree of the erXos repository or in a repository that is not
  separate from it.
* **The landing gate measures; it does not judge speed.** A `bench` QEMU
  suite runs a fixed landing matrix of the five benchmarks in three boots
  the gate can reuse, and reports each against the newest recorded
  baseline. A cell fails for a hard limit, a wrong answer or a benchmark
  that did not run in full; a passing suite says the benchmarks ran, not
  that a change brought its before and after numbers.
* **Other systems run on the same board.** Stock L4Re, FreeBSD and Linux
  boot on the same Raspberry Pi 4, with the same firmware settings, and run
  the counterpart of each operation: L4Re's own IPC benchmark, and for
  FreeBSD and Linux one portable C program, `bench/peer/erx_peer_bench.c`,
  compiled on the board by the system's own compiler. Linux serves as the
  best-case comparison on the board, FreeBSD as the behaviour erXos
  matches; an operation with no counterpart says so.
* **On the board, the board walks its own boots.** The host's boot
  server hands the n-th download the n-th entry of a queue of signed
  boot images, each naming its boot with a name the host chose, and
  every later download the last entry, the pair the board was found
  with; every bench boot ends with a reset, so the board boots the next
  entry by itself, and the host changes nothing while it does
  ([Running on the Raspberry Pi 4](#running-on-the-raspberry-pi-4)).

## Context

### The problem

Three facts from the tree set the scope.

* **The costs that hurt are below the runtime.** On the Raspberry Pi 4 the
  probe found Fiasco's own path under 10 us and the rest of a 0.6 to 6 ms
  delay with the console driver's ERTS scheduler awake but not running,
  behind other threads of its priority on its CPU; the mini UART's FIFO
  holds 0.7 ms of input, so pasted bytes were lost
  ([design-fiasco.md, Urgency](design-fiasco.md#urgency), "The evidence";
  history repository `pi4/2026-11-22-irq-probe/`). None of the existing
  benchmarks would have shown it: they time Erlang workloads in batches
  ([What the existing tools do](#what-the-existing-tools-do)).
* **Designs already promise numbers nobody can produce.** The Fiasco
  design decides whether to carry its branch-predictor patch by timing the
  null request on the board, ten runs a build
  ([design-fiasco.md, The release's Fiasco build](design-fiasco.md#the-releases-fiasco-build),
  FD32); gate G5 needs `xdomain-pingpong` and `xdomain-throughput`
  ([design-domains.md, Performance](design-domains.md#performance)); the
  watch list names about twenty-five workloads that `tools/erx bench` refuses as
  unknown ([todo-performance.md](todo-performance.md)); and CLAUDE.md asks
  every change to the boot path, kernel entry, scheduler, IPC, domain
  creation or cross-domain messaging for before and after numbers.
* **There is no history.** The records that exist were written by hand
  into the history repository (`bench/g3/2026-11-06/`, `bench/g5/2026-11-09/`,
  `pi4/2026-11-22-irq-probe/`), each in its own shape, so no tool can say
  whether a new number is worse than an old one.

### Consumers

| Consumer | What it needs from this design |
| --- | --- |
| FD32, the branch-predictor patch ([design-fiasco.md](design-fiasco.md#the-releases-fiasco-build)) | `nullcall`'s decoder-refusal round trip on the Raspberry Pi 4, two release builds, ten runs each, judged by FD32's own predicate ([FD32's decision](#fd32s-decision)) |
| The Raspberry Pi 4's interrupt measurement ([design-fiasco.md, Verification](design-fiasco.md#verification)) | the console and SD receipts per load cell, recorded and judged against 0.7 ms and 1 ms |
| Gates G3, G5, G8, G9, GK3, GP and G6 ([plan.md](plan.md#decision-gates)) | the same benchmarks on QEMU under HVF, Fiasco's numbers as the baseline erXos's kernel is later held to |
| The scheduler's E-S1 to E-S10 and the domains' E-D1 to E-D4 ([design-scheduler.md](design-scheduler.md#performance), [design-domains.md](design-domains.md#performance)) | named workloads with distributions, not batch means |
| The watch list ([todo-performance.md](todo-performance.md)) | a recorded number to settle each item |
| CLAUDE.md, "Latency is UX" | the before and after of a change, with host, accelerator, QEMU version, compiler, flags, workload and baseline |

### The published numbers erXos is set against

These are the numbers a fair comparison can use, read on 2026-11-23 from
the sources in [References](#references). None is a target in itself:
erXos runs L4Re's benchmark on its own board and compares with that run,
and every other row stays context.

| System | Hardware | Operation | Number | Fair against erXos because |
| --- | --- | --- | --- | --- |
| L4Re, Fiasco without virtualization support | Raspberry Pi 4, Cortex-A72 | IPC between two tasks, same core | 702 cycles | same board, same kernel family and privilege level: erXos's Fiasco is also built without virtualization support (`CONFIG_CPU_VIRT` off, `config/fiasco/kernel.defconfig`); L4Re's rows also used its benchmarking build, which erXos's is not |
| the same | the same | IPC between two threads of one task | 505 cycles | the same |
| the same | the same | null system call | 305 cycles | the same |
| L4Re, Fiasco with virtualization support | the same | IPC between tasks; null call | 1,600; 567 cycles | context only: the build erXos does not use, which the page says the A72 makes much slower |
| seL4, default configuration | Jetson TX1, Cortex-A57, 1.9 GHz | call; reply (each one way) | 419; 431 cycles | context only: a similar core, another board, and means with deviations |
| seL4 | the same | notification; interrupt to a user handler | 1,083; 882 cycles | context only |
| Linux with PREEMPT_RT, 64-bit | Raspberry Pi 4 | worst wake lateness under a kernel build | about 230 to 270 us | context only: single runs read by hand, maxima only, a load erXos would have to imitate |

L4Re's page does not say whether "a single IPC" is one way or a round
trip, or the clock it ran at; both are why erXos runs it on its own board
rather than divides by it, and why a difference is attributed to the
root service only once the run's IPC direction, payload, statistic and
configuration are known from the benchmark's source. No published Arm number exists for
cross-core IPC, page faults, mapping, thread or process creation, pipes or
the 99th percentile of a Pi 4 wake; erXos measures those on FreeBSD and
Linux itself.

## What the existing tools do

`tools/erx bench NAME` dispatches by a chain of name tests in `tools/erx`
(`self.bench`) to one runner per benchmark:

| Name | Runner | What it times |
| --- | --- | --- |
| `otp-pingpong`, `otp-ring`, `otp-spawn`, `otp-switch` | `tools/lib/erx/bench.rb`, workload `bench/erx_otp_bench.erl` | stock OTP on the host, one scheduler; nanoseconds per operation as the mean of each of seven batches |
| `g3` | `bench_g3.rb`, `bench_guest.rb` | the same four inside an erXos guest, typed into its shell, against stock OTP; the footprint; boot to the shell |
| `boot` | `bench_boot.rb` | host-clock times from QEMU's start to four boot checkpoints |
| `g5` | `bench_g5.rb` | interpreter against BeamAsm domains on one workload |
| `bytes` | `bench_bytes.rb` | the network primitives of `erx_bytes` |
| `web` | `bench_web.rb` | a record view's round trip over the host tool's web front end |
| `net-freebsd` | `net_bench.rb`, `net_bench_freebsd.rb` | `erx_net` against lwIP on the FreeBSD x86-64 test host |

`BenchMeasurement` (`bench_measurement.rb`) checks that a measurement says
the workload, sizes and flavour asked for and holds one positive finite time
per sample, and never echoes a guest's text. The QEMU suites hold the
nearest thing to latency tests: `native_irq` rings a software IRQ object
when it sees an executor parked, across CPUs where there are several
(`test/guest/native_irq/guest.c`), and `native_task` holds the band case
and a quantum case whose median turn must lie within 250 to 4,000 us around
a 1 ms slice (`test/guest/native_task/guest.c`, `case_band`,
`case_quantum`). The root's trace ring stamps parks, wakes and IRQ
deliveries with `erx_clock_ns`
([design-fiasco.md, The trace ring](design-fiasco.md#the-trace-ring)). The
stamps the interrupt probe took at Fiasco's interrupt entry exist only on
the diagnostic branch `uart-irq-probe`, which is marked not to land.

Three defects follow from each runner owning its own output and its own
idea of a comparison:

* **`g3` sets TCG against native.** `BenchG3.report` computes the guest
  over stock ratio for whichever accelerator the plan names, `tcg`
  included, though the stock side runs natively and CLAUDE.md forbids the
  comparison; the class's own comment says only that TCG and HVF are never
  compared with each other.
* **`otp-switch` does not measure a switch.** Its two processes call
  `erlang:yield()` in loops, and the module counts two switches per yield
  (`operations(switch, Yields) -> 2 * Yields`) without observing that the
  other process ran in between.
* **Results are written into the tree.** Every runner writes its report
  under `build/bench` and its boots under `build/qemu`
  (`OutputDirectory.prepare` in `bench.rb`, `bench_g3.rb`, `bench_boot.rb`,
  `bench_bytes.rb`, `bench_g5.rb`, `bench_web.rb`; `net-freebsd` defaults
  to `build/bench/net-freebsd-STAMP`), where a clean build deletes them and
  no other worktree or host sees them, and `docs/design.md` lists `bench/`
  as holding "recorded results".

Below the tools, what erXos can be asked on Fiasco bounds what a benchmark
can time: `erx_ipc_call`, `erx_ipc_send`, `erx_ipc_reply`,
`erx_ipc_reply_wait` and `erx_thread_set_urgency` answer `ERX_ENOTSUP`
(`liberx/backend/core/refused.c`); `erx_mem_child` makes an eager copy
(`liberx/backend/fiasco/service_stubs.c`); a doorbell's trigger is the
holder's own `l4_irq_trigger` and makes no request (`erx_irq_trigger`, the
same file). Fiasco's timeouts and slices are driven by a periodic 1 ms tick
in erXos's configuration
([design-fiasco.md, Scheduling](design-fiasco.md#scheduling), "The
quantum"); whether a timed park can end only at a tick is unverified, and
the `wake` benchmark is what shows it.

## The construction

The design has one record type and pure functions over it. A benchmark
produces samples; everything after that (summaries, percentiles, statuses,
comparisons, gate verdicts, side-by-side tables) is computed from records
by one Ruby module, `Erx::BenchRecord`, and its comparison,
`Erx::BenchCompare`, so no runner decides for itself what a number means.

### A benchmark

A benchmark is a file, `tools/lib/erx/benches/NAME.rb`, as a QEMU suite is
([design-build.md, What the gates run](design-build.md#what-the-gates-run)).
It declares:

* its **operations**, each an exact act with a start and an end on one
  clock, and what a correct result of the act is (a status, a reply, a
  count);
* its **profile** per operation (below), with only the parameters that
  differ from the profile's defaults; a periodic operation whose timer
  takes only deadlines it rounds itself is declared `sweep: false` and
  takes no phase sweep;
* the **environments** it runs in, and for each the image and the guest
  program that run it;
* the **load cells** it runs under, each a named background (idle, a
  spinner on the same CPU, a neighbour domain's loop);
* its **counterparts** on the other systems
  ([Other systems](#other-systems-on-the-same-raspberry-pi-4)), each with
  one line saying what differs.

`tools/erx bench NAME` finds the file by its name; the chain of name tests
in `tools/erx` goes, and the existing runners become the `run` of their
declarations. A name a design document gives and no file declares is
refused as unknown, as it is today.

A **cell** is one operation under one set of conditions: its load cell,
CPU placement (`same-cpu`, `cross-cpu`, `service-cpu`, `other-cpu`, or
`runtime` where a runtime's own scheduler places the work on a CPU the
cell does not choose), workload parameters (a size, a thread count, a priority),
clock and batch size. A guest reports each cell as one line on its
console, `BENCH` followed by one JSON object of at most 64 KiB, in clock
ticks: the benchmark, the operation, the cell's conditions, the clock and
its frequency, the status, the sample count, the batch size, the
histogram, the exact maximum and minimum, the sixteen largest samples with
their sequence numbers, and the counts of lost, early and missed events.
A swept periodic cell adds its sixteen phases and its excess histogram;
an unswept one carries neither, and a line that carries them for an
unswept operation, or lacks them for a swept one, is refused. A
sustained cell's samples are windows, not ticks, and reach the host in
lines of their own ([A sustained cell](#a-sustained-cell)).
`BenchMeasurement` grows into the one validator of these lines; it checks
every field's type and bound, refuses a line whole with a reason that
never quotes it, and is fuzzed
([Verification](#verification)).

A guest reports its clock's calibration ([The one clock](#the-one-clock))
as one more line per boot, `CLOCK` followed by one JSON object, printed
after its last cell's calibration: the clock and its frequency, the
smallest increment two reads observed, the median cost of a read, the
rounding of a timed wait, the CPU's cycles per counter tick as a number,
or `unknown` where the run could not measure it, and for each pair of
CPUs a cell stamped across, lower CPU first, the offset interval
measured before the cells and the one measured after them, each as its
lowest and highest offset in ticks, or null where that calibration's
stamps contradicted each other.
The record's `clock` group is that line's object. `BenchMeasurement`
validates it as it does a `BENCH` line, with the same refusals, and the
one fuzz target takes the guests' `CLOCK` lines as seeds beside their
`BENCH` lines. The guest, not the host, applies the cross-CPU rule: it
prints a cell stamped across a pair only once both intervals are
measured, corrects its samples by the hull's middle and gives the
hull's half-width as the cell's `uncertainty`, and otherwise marks the
cell `unsupported` with the reason that applies: `counters across CPUs
contradicted each other` when either interval is null, `counters across
CPUs moved during the run` when the two intervals do not overlap, and
`counters across CPUs not bounded closely enough` when the hull's
half-width is more than a tenth of the cell's median. The host holds a
`measured` cell to the same bound, against its median bucket's upper
end, and refuses one whose `uncertainty` exceeds it. A boot whose
`BENCH` lines arrive without exactly one valid `CLOCK` line has no
calibration, and its cells are `rejected`; so is a cell whose frequency
is not its `CLOCK` line's. A `failed` cell stays `failed` in both only
when its failure does not depend on the clock (a lost wake, a wrong
status), and then carries only its status, reason and counts, no tick
statistics; a failure judged with the clock, an early return, is
`rejected` like the cells that did not fail.

The runner holds a boot's lines to what it asked the guest for: the
declared cells of every benchmark the boot runs, the line's `benchmark`
field selecting among them, the clock its environment reads, and the
pairs of CPUs its two-CPU cells span. A `BENCH` line is refused when its
operation, load cell, placement and workload parameters are not one
declared cell, when its clock is not the environment's, when it repeats
a cell, or when it times across two CPUs in a boot that calibrated no
pair; a `CLOCK` line is refused when its clock is not the environment's
or its pairs are not exactly the boot's. A declared cell no accepted
line reports is `not_run`, `timed_out` when the boot ended at a QEMU
deadline before reporting it, or `rejected` when one of the boot's
`BENCH` lines was refused, since that line may have been its own. One
`CLOCK` line serves every benchmark of a boot. A boot that ends at a
deadline is still recorded, from the lines its serial log holds, and
ends no other boot of the run.

### The histogram

A guest does not send raw samples: on the Raspberry Pi 4 its console runs
at 115,200 baud, about 11 KiB a second, so 100,000 samples of one
operation would take a minute to send. It sends a histogram whose buckets
are powers of two split into 64 equal parts, so a bucket is at most 1/64
(1.6%) of its lower bound wide, finer than any advisory threshold. Each
non-empty bucket is sent as its own bounds and count, so the reader
needs no formula: the C library of the guests (`test/guest/bench/`) and
the Erlang one (`bench/erx_bench_hist.erl`) each build their histogram,
and neither has to agree with the other bit for bit. A percentile is
reported as the upper bound of the bucket it falls in, so it never claims
an operation was faster than it was. An expensive operation with at most
1,000 samples also sends its raw samples.

### The one clock

Every interval a record holds is the difference of two reads of one clock,
and the record names the clock:

| Clock | Read by | Used for |
| --- | --- | --- |
| `counter` | `erx_fiasco_counter`, the one read of the architecture's system counter in an erXos program; `erx_clock_ns`, ERTS's monotonic time and the trace ring's stamps all derive from it | every interval inside a guest |
| `host` | the host's monotonic clock | what only the host sees: QEMU's start to a boot checkpoint, a web round trip |
| `analyser` | the logic analyser's sample clock | an edge on one pin of the Raspberry Pi 4 to an edge on another |
| `virtual` | `counter` in deterministic mode, which QEMU drives from instruction counting (`-icount shift=0,sleep=off`, `tools/lib/erx/qemu.rb`) | deterministic virtual time: the same at every run of the same inputs, but not a count of instructions, since with `sleep=off` QEMU's documentation says virtual time jumps to the next timer deadline while the CPU sleeps (unverified against the pinned QEMU) |

A guest's samples are in ticks; nanoseconds are derived when the record is
read, from the frequency the run recorded. Cycles are a unit, not a clock:
a number in cycles is a counter interval times the CPU frequency that the
same run measured, and is `unknown` where the run could not measure it.

**Calibration.** Each run of a guest benchmark first measures its clock,
in under a second, and records:

* the counter's frequency, from its frequency register (24 MHz under HVF
  and 62.5 MHz under TCG on the primary host,
  [research-baselines.md](research-baselines.md#exception-and-address-space-switch-costs));
* the smallest increment two reads observe, and the median cost of a read,
  from 10,000 back-to-back pairs;
* for each pair of CPUs on which a cell reads its start and end stamps,
  an interval that holds their counters' offset. Thread A, on one CPU,
  stamps `a` and passes a token through shared memory, with no kernel call; thread B, on
  the other, stamps `b` on receipt and passes it back; A stamps `c` on its
  return. Causality gives `b - c <= offset <= b - a`, each end widened by
  the smallest increment. Over 1,000 rounds the offset lies in the
  intersection: from the largest `b - c` to the smallest `b - a`. Each
  round's interval holds the offset whatever its transfers took, so a
  50-tick offset hidden inside 100-tick transfers stays inside the
  interval instead of passing as zero; rounds whose transfers split
  differently narrow the intersection, and an empty one means the stamps
  contradict each other: the interval is carried as null and the cells
  across that pair are `unsupported`. The construction assumes the
  offset does not change during the run, so calibration runs again after
  the run's cells, and the cells across that pair are `unsupported`
  unless the two intervals overlap, and are otherwise bounded by their
  hull, which holds the offset however it moved between them;
* the rounding of a timed wait (`erx_fiasco_time_wait_us` rounds a
  deadline up to the microsecond, `liberx/backend/fiasco/time_table.c`),
  so lateness under a microsecond is recorded as unresolvable;
* on the Raspberry Pi 4, the CPU's cycles per counter tick over one second,
  which a disposable test task measures where its cycle counter is
  readable in user mode ([The cycle counter](#the-cycle-counter)), and
  otherwise `unknown`; the `CLOCK` line carries it as a number or
  `unknown`.

The rule applies to a cell whose start and end stamps are read on
different CPUs; a round trip stamped on one CPU needs no calibration,
wherever its work ran. Such a one-way interval is corrected by the
interval's middle and reported with its half-width as its uncertainty,
and its cell reports `unsupported` with the reason of the `CLOCK`
paragraph in [A benchmark](#a-benchmark) when an interval is null, the
two do not overlap, or the half-width is more than a tenth of its
median.
A round trip is never halved into a one-way number.

**Short operations.** An operation whose warm-up median is under 100
ticks is timed in batches: the smallest power of two of operations that
spans 100 ticks. The record states the batch size, and its percentiles
are of batch means; they are never called per-operation tails. An
operation timed as a handshake (`wake-same-cpu`, `wake-cross-cpu`,
`trigger-take`) is exempt, because B must return before A pokes again,
so its operations cannot run back to back: its declaration marks it a
handshake, its cell reports batch 1 whatever its median, and the host
refuses a line of it in any other batch. Such a cell carries the `CLOCK`
line's read cost and smallest increment in its operation file beside
its samples, so a median of a few ticks shows how coarsely the clock
resolved it. A sample is never corrected by subtracting the read cost;
the cost is recorded beside it.

### Profiles

A profile fixes how an operation is sampled and what its summary may
claim. Its two sizes are the landing form, run at the landing gate, and
the full form, run at the gates that name the benchmark and on demand.
A run is one boot of each image the benchmark needs. The sizes are
starting values, to be revised by the first calibration runs.

| Profile | Sampling | Landing form | Full form | Summary |
| --- | --- | --- | --- | --- |
| **fast** | warm-up, then each operation timed alone | 1,000 warm-up, 10,000 samples, one run | 1,000 warm-up, 100,000 samples, three runs | histogram, percentiles the count allows, minimum, maximum |
| **expensive** | 10 warm-up operations, or none for a cold start, then each timed | 10 and 100, one run | 10 and 1,000, three runs | median and maximum, the raw samples, percentiles the count allows |
| **periodic** | absolute deadlines on a fixed schedule of period P and a phase sweep (below); each period's lateness is its return less its deadline | P = 1 ms for 2 s | P = 1 ms for 60 s, three runs; 300 s at the gates that name it | the lateness histogram per phase; early returns, missed periods and lost wakes counted |
| **sustained** | after a 2 s warm-up, windows of fixed length, in each of which every thread of the cell counts its passes and its gaps ([A sustained cell](#a-sustained-cell)) | three 1 s windows | five 10 s windows, three runs | per window and thread its share of the CPU, longest gap and lost turns; the longest gap over all windows |

Two rules hold in every profile, so no benchmark declares them:

* **A percentile is reported only when at least ten samples lie above
  it.** Of n samples in order, percentile p is the sample of rank
  `ceil(p * n)`, reported as its bucket's upper bound, and it is reported
  when `n - ceil(p * n) >= 10`: the median needs 20 samples, the 99th
  percentile 1,000, the 99.9th 10,000, and one sample fewer reports
  `unsupported: too few samples` for it.
* **A periodic deadline never moves.** Deadline k is fixed before the
  run starts, whatever happened before it, so a stall shows as missed
  periods and lateness and is not absorbed into the schedule, as
  cyclictest's absolute mode does. A return before its deadline is
  counted as early, which is a wrong answer.
* **The phase sweep.** A timer that fires only on a periodic tick makes
  a deadline's lateness depend on where the deadline falls between two
  ticks, and deadlines a whole period apart would all fall at one phase,
  set by when the run happened to start. Deadline k is therefore the first
  deadline, plus k periods, plus `(7k mod 16) / 16` of a period, which
  visits sixteen phases in turn. Within a run, lateness is reported per
  sweep phase as the minimum observed lateness and the excess above that
  minimum. The minimum holds the timer's rounding together with whatever
  delivery and scheduling cost every period paid, so it is not called
  rounding, and the excess is not called scheduling delay; telling them
  apart needs a stamp of the timer's own firing, which no cell has. A
  sweep phase is counted from the run's first deadline, not from the
  tick, so phases are not matched across runs: comparisons use the
  distribution over all phases. Whether Fiasco's timed waits end only at
  ticks is unverified; a minimum that varies across the phases by about a
  tick is the sign of it.

### A sustained cell

A sustained cell shows how a CPU is shared, which no single timed act
does. Its threads are **recording spinners**: each reads the counter in a
loop on the one CPU it shares with the cell's other threads and its
load. A **gap** is the ticks between two of a thread's reads; its first
gap counts from the plan's start, before any thread started, so a thread
that starts late shows the wait as a gap.

* **The windows.** The plan is fixed before any thread starts: a 2 s
  warm-up, then the profile's windows, each of fixed length, so every
  thread's window k is the same span of the counter. The read that passes
  a window's end is that window's last, and a window no read fell in is
  one gap of the window's whole length, with no pass.
* **A lost turn** is a gap longer than half the slice the root
  configures (`ERX_FIASCO_ROOT_SLICE_US`), converted to ticks with the
  counter's frequency: for that long the CPU ran something else, another
  thread's turn, or the host held the guest's CPU. The threshold is a
  time, not a count of loop passes, because a pass of the loop takes less
  than one counter tick under HVF, so a pass-counted threshold would take
  in a tick's worth of interrupt handling. It is half the configured
  slice, not the slice a thread was given, so a thread given a longer
  slice still has its turns counted.
* **What a thread keeps per window**: its passes (`iterations`), its
  longest gap (`longest`, ticks), its lost turns (`lost`) and the ticks
  they took (`waited`). Its **share** of the CPU in the window is
  `1 - waited / window`, the part of the window it was not kept off the
  CPU for half a slice or more. This accounting is a pure function of the
  thread's reads and the plan, in the guest bench library, built and
  tested on the host as the periodic classifier is.

**How a sustained cell is reported.** A test task runs the spinners, and
a task reaches the console only through its write, not through the root.
So the task writes the cell's samples, and the root, which knows the
cell, names it:

1. The task's first thread, on CPU 0, writes nothing while a window
   runs, where a write perturbed it. Once every spinner has published its
   last window, it writes one `WINDOW` line per window and thread, window
   by window and thread by thread, each `WINDOW` followed by one JSON
   object:
   `WINDOW {"window":0,"thread":2,"iterations":81234567,"longest":98765,"lost":250,"waited":18000000}`.
   A line is at most 160 bytes, well inside one task write
   (`utcb_bytes_max`, 504 bytes), which the root's one service thread
   writes to the console whole, so no other task's write lands inside it.
   The task ends with 0 once every line is written.
2. The root, having joined the task, prints the cell's `BENCH` line: the
   fields every cell carries, with `samples` the cell's window count and
   no `histogram` or `largest`, since a window is not a tick sample. Its
   status is `measured` when the task ended with 0 and `failed`
   otherwise, the reason naming the task's status (a spinner that
   publishes no window in time is one such end).
3. The cell's windows are the `WINDOW` lines between the boot's previous
   `BENCH` line and this one. `BenchMeasurement` reads `WINDOW` lines as
   it reads `BENCH` and `CLOCK` lines, with the same decoder and
   refusals, and the one fuzz target takes the guests' `WINDOW` lines as
   seeds beside the others. It holds them to the cell: exactly one line
   for each of the cell's windows and threads (the `threads` parameter),
   in the order written; otherwise the cell is `rejected`, naming the
   first missing or misplaced line. `WINDOW` lines followed by a `BENCH`
   line of another profile, or by none, are refused.
4. A `measured` cell in which a thread made no pass in some window is
   `failed`: its correct result is that every thread runs in each
   window, and the reason names the thread and the window.

The record keeps a sustained cell's windows as its detail, and its
summary is derived from them: per window and thread the share, the
longest gap and the lost turns; per window the smallest share over the
largest; and the longest gap over all windows, the statistic a
comparison judges ([Comparison](#comparison)). Its windows are few, three
or five, so it reports no percentile: the percentile rule gives none
under 20 samples. The window's length is a workload parameter of the
cell (`window-ms`), the warm-up is the profile's, in milliseconds, and
both become ticks at the cell's frequency, which is the boot's `CLOCK`
line's, since every thread reads the same counter.

### Environments

An environment is where a run happened. Its name is derived, never
written by hand, and carries no host name:

| Kind | Name | Holds | Compared with |
| --- | --- | --- | --- |
| QEMU `virt` under HVF | `qemu-hvf-<model>-<n>cpu`, `<model>` the host's hardware model | the development numbers and the landing gate | itself; side by side with `host` |
| QEMU `virt` under TCG | `qemu-tcg-<model>-<n>cpu` | functional runs on hosts without HVF | itself only |
| deterministic mode | `qemu-det` | deterministic virtual time of one CPU, the same at every run of the same inputs | itself only |
| the Raspberry Pi 4 | `pi4-4gb-<system>`, `<system>` one of `erxos`, `l4re`, `freebsd`, `linux` | the native numbers and the three limits | itself; side by side with the other systems on the board |
| the host | `host-<model>` | stock OTP natively | side by side with `qemu-hvf` |

QEMU's `raspi4b` model is not an environment: it runs only under TCG, and
its numbers describe the model. Under HVF, a guest's CPU affinity does not
pin the host thread that runs it, and macOS has no way to; the record
keeps the host's load average before and after.

### The record

One run is one invocation of `tools/erx bench`: one or more boots of one
subject in one environment. Its directory is
`<history>/bench/<environment>/<run>/`, where `<history>` is
`ERX_BENCH_HISTORY` or `~/erxos-history`, and `<run>` is the UTC time,
the source revision's first twelve hex digits and `-dirty` when the tree
was:

```
run.json                     the manifest
<benchmark>/<operation>.json every cell of the operation, each keyed by its
                             conditions, with its histogram, largest samples
                             and raw samples if few
boot-<n>.serial.log          each boot's console
boot-<n>.qemu.log            each boot's QEMU output
compare.json                 a comparison made against this run, if any
```

`run.json` holds, as CLAUDE.md requires and the comparison needs:

| Group | Fields |
| --- | --- |
| environment | kind, machine model, CPU count, memory, operating system and its version, accelerator, QEMU version and machine type, firmware files' SHA-256 on a board |
| subject | source revision and whether the tree was dirty, image SHA-256, every workload source's SHA-256, compiler version, the complete compile and link flags, the system manifest, runtime flavour and scheduler flags, the Fiasco configuration |
| run | date, the tool's revision, what started it (`landing`, `milestone`, `gate G5`, `manual`), the host's load before and after, a board's temperature and throttle state at the start and end where readable, `reused_from` for a reused boot |
| clock | the calibration above |
| cells | per cell: benchmark, operation, the cell's conditions (load cell, placement, workload parameters, clock, batch size), profile and its sizes, status and reason, sample count, the summary the profile allows, lost, early and missed counts, and its operation file |
| baseline | for a run that was compared: the baseline run's path |

A cell's status is one of:

| Status | Meaning | Summary |
| --- | --- | --- |
| `measured` | every sample asked for was taken and every result was correct | in full |
| `partial` | fewer samples than asked, with the reason (a deadline, a load that ended) | from the samples taken, labelled partial |
| `timed_out` | the guest's deadline passed before the operation reported | none |
| `unsupported` | the call answered `ERX_ENOTSUP`, the environment lacks what the operation needs (a second CPU, a readable cycle counter), or calibration could not bound its counters; the reporter is named | none |
| `failed` | a result was wrong: a lost wake, an early return, a reply with the wrong status, a thread of a sustained cell that did not run in a window | the samples before the failure, and the failure |
| `rejected` | the guest's line failed validation, a sustained cell's `WINDOW` lines were not exactly its windows and threads, or a cell came from a boot without exactly one valid `CLOCK` line or with a frequency not its `CLOCK` line's and did not fail on a result the clock did not judge (a lost wake, a wrong status), which stays `failed` with its counts and no summary | none, and the reason |
| `not_run` | expected and never reported | none |

A file is at most 1 MiB, a log at most 64 MiB, and a run directory is
created exclusively, never over another. Every file name is derived from
the validated declarations (benchmark and operation names), never from
a guest's line. Records are never edited; a
number changes by a new run. A record of an older format is refused with
a diagnostic, never read.

**Where records are written.** `Erx::BenchRecord.write` is the only
writer. It refuses the history root unless it exists, is the top of a
git work tree whose common git directory is not the erXos repository's,
and lies, by real path, outside every worktree `git worktree list` gives
for the erXos repository. It also refuses a history root that shares a
root commit with the erXos repository, the roots of each taken over
every ref (`git rev-list --max-parents=0 --all`), so a second clone of
erXos, which has a common git directory of its own, is never a history
root whatever branch either has checked out; a shallow repository,
whose roots git cannot list, is refused, and so is any git failure
while listing them. It then checks the destination itself, not
only the root: it walks from the root to the run directory one
component at a time, refuses any component that is a symbolic link, and
refuses unless the run directory's real path lies under the root's and
outside every erXos worktree. A missing root is refused, never replaced
by a fallback.
The separate repository is identified by these derived facts; no
marker file declares it. Scratch work (images being
built, the boot directories QEMU writes into) stays under `build/` and is
deleted; what is kept is copied into the record. The tool commits nothing
and deletes nothing in the history repository: a run is kept by
committing it there by hand, and an uncommitted run is scratch.

### Comparison

`BenchCompare` is a pure function of records. It compares one statistic
(the median, 99th and 99.9th percentiles, the maximum, or a sustained
cell's longest gap) of one cell between a **baseline**, at least three runs, and a
**candidate**.

* **Comparable.** The two sides must have equal environments and equal
  cells: the same operation, load cell, placement, workload parameters,
  clock, batch size and profile sizes. Anything else is refused with what
  differs. The one exception is the side-by-side table, which sets
  `qemu-hvf` beside `host` for G3 and one board's systems beside each
  other, and gives no verdict.
* **The noise band.** The band of a statistic is the range of its values
  across the baseline's runs, widened by one histogram bucket.
* **The verdict.** `same` when every candidate run lies within the band;
  `slower` when at least two of three candidate runs lie above it and the
  candidates' median exceeds the baseline's by more than the advisory
  threshold; `faster` the mirror; `inconclusive` otherwise. A sustained
  cell is judged on its longest gap over all windows, an exact number
  whose band is not widened, against the 99th percentile's threshold,
  since it is the cell's tail. Deterministic mode's band has no width,
  so any difference there is a real change of the measured virtual time,
  though not necessarily of instructions executed.
* **Inconclusive is not a pass.** A comparison is inconclusive when the
  baseline has fewer than three runs, when either side's cell is not
  `measured`, when either host's load average exceeded half its CPUs (a
  starting value, revised with the thresholds), or when the verdict above
  is mixed. A change that CLAUDE.md requires numbers for has not
  supplied them while its comparison is inconclusive, whatever the suite
  that ran it reported.
* **A replayed boot is not a new run.** A log the gate's store replays
  ([The gates](#the-gates)) is evidence of the run that recorded it. It
  never counts as a calibration run, an independent baseline run or a
  side of a paired run.
* **Maxima and misses stand apart.** A maximum, a missed period or a lost
  wake is reported in every comparison even when every percentile is
  `same`.

**Paired runs.** On a shared host, a baseline recorded last week and a
candidate run today differ by everything else the host did. Only a paired
comparison can say `slower` or `faster`: `tools/erx bench NAME --paired
--image-a BASE --image-b CAND` boots the two images alternately, three
times each (A B A B A B), on one host in one session, and compares them by
the rule above. The developer builds the two images; the tool builds
nothing. A comparison with a recorded baseline and one candidate run, as
the landing gate makes, can say only `same` or `outside the band`, the
second meaning that a paired run is needed.

**Advisory thresholds.** The thresholds below are starting values. After
the first three runs of an unchanged subject in an environment, each
becomes the larger of its starting value and the spread those runs
showed, recorded with the runs. They never fail a gate.

| Environment | Median | 99th percentile | 99.9th percentile |
| --- | --- | --- | --- |
| the Raspberry Pi 4 | 5% | 10% | 20% |
| QEMU under HVF | 10% | 20% | 30% |
| deterministic mode | any change | not reported | not reported |

### FD32's decision

The comparison above is advisory and does not decide FD32. Whether the
Fiasco fork carries its branch-predictor patch is decided by the predicate
[design-fiasco.md](design-fiasco.md#the-releases-fiasco-build) states,
unchanged: `nullcall.root-cross-space` timed on the Raspberry Pi 4, on a
release build with the patch and one without, each run at least ten
times, and the patch carried when the patched build's median round trip
lies within the spread of the unpatched build's medians across its runs.
The tool computes that predicate as a function of its own, beside the
advisory comparison and never through it:

* each run's median is the run's own, from its histogram;
* the spread is the smallest to the largest of the unpatched runs'
  medians, with no widening;
* the patched build's median is the median of its runs' medians, each
  run's reported beside it (the reading of "the patched build's median"
  that [the decision on FD32's ten runs](#how-fd32s-ten-runs-combine) fixes);
* where the patched median lies within one histogram bucket of either end
  of the spread, the answer is `inconclusive: within the histogram's
  resolution of the spread's edge`, and more runs, or raw samples, settle
  it; the tool never rounds such a case to an answer.

### The three limits

Exactly three limits fail a gate, each becoming hard once three runs of it
are recorded in its environment; until then each is reported as the
others are:

| Limit | Measured by | Where it fails |
| --- | --- | --- |
| **No lost wake.** A thread woken while parked returns `ERX_OK`; a wake whose park ends with `ERX_ETIMEDOUT` instead, or never ends, is lost | the `wake` benchmark's handshake operations, and every operation that wakes | every environment, every gate the `bench` suite runs at |
| **The console's line within 0.7 ms**, with no receive FIFO overrun and no refused line | the Raspberry Pi 4's interrupt measurement, in the cells [design-fiasco.md](design-fiasco.md#verification) names as passing | a board's record; a milestone or release that ships on the Raspberry Pi 4 is not reached while its build's latest record fails it |
| **The SD controller's line within 1 ms** | the same measurement | the same |

The two board limits keep the definition the Fiasco design gives them,
from Fiasco's interrupt entry to the driver's process, each cell's longest
receipt recorded. How that entry is stamped in a build that is not a
diagnostic one is the development-only Fiasco patch of
[The interrupt entry's stamp](#the-interrupt-entrys-stamp). A board record
from a build without it holds the receipt from the first user-mode stamp
on the path, and the two limits read `partial: no kernel entry stamp`
rather than pass.

## The gates

| Tier | What runs | What fails it |
| --- | --- | --- |
| **Landing**, with the QEMU suites a change touches | `tools/erx check-qemu --suite bench`: the landing matrix below | a suite cell that is not `passed` (table below) |
| **Milestone** | `make check-qemu` runs the `bench` suite fresh, as every suite; the full matrix runs by hand, and joins this gate only when CLAUDE.md's milestone gate list names it ([The full matrix](#the-full-matrix)) | the same |
| **Plan gates and on demand** | `tools/erx bench NAME --profile full`, `--paired`, FD32's runs, and the Raspberry Pi 4's runs by hand | the board limits, for the milestones that ship on the board |

**The landing matrix.** Three boots, each running its cells one after
another and never two at once, so that sharing a boot changes no cell's
background:

| Boot | Cells |
| --- | --- |
| the native bench image, QEMU `virt` under HVF, four CPUs | `nullcall`: `root-same-space` and `root-cross-space` on the service's CPU, and `kernel`; `vm`: `reserve`, `commit`, `touch`, `protect`, `decommit` and `release` of one page, from a test task; `wake`: `wake-same-cpu`, `wake-cross-cpu` and `trigger-take` on one CPU, and `park-deadline` on one CPU, idle, for 2 s; `sched`: `share-equal` with four spinners on the last CPU, three 1 s windows |
| the same image in deterministic mode | `nullcall`'s two root cells and `vm`'s one-page `commit` and `protect`, 1,000 samples each |
| the `xdomain` bench image, under HVF | `xdomain`: `local-rtt` and `xdomain-pingpong`; `wake`: `erlang-timer` at `normal`, idle, for 2 s |

Every fast cell takes the landing form's 10,000 samples. The timed work
is about 10 s; the rest of the suite's time is three boots and their
calibration, which the suite measures and records. Its target is about a
minute. If its recorded time passes that, the deterministic boot moves
to the milestone gate. Every other cell, load and placement is in the
full matrix only.

**Cells and suite cells.** The `bench` suite is an ordinary QEMU suite
(`tools/lib/erx/qemu_suites/bench.rb`). Its suite cells, in the sense of
[design-build.md, What the gates run](design-build.md#what-the-gates-run),
are its benchmarks in each boot, and each takes the worst status of the
benchmark's cells there:

| A benchmark cell's status | Suite cell |
| --- | --- |
| `measured` | `passed` |
| `unsupported`, where the declaration expects it in that environment (a cell that places work on two CPUs, in deterministic mode) | `passed`, the cell listed as unsupported |
| `unsupported` anywhere else, `partial`, `rejected` | `partial`, which leaves the suite incomplete and fails the gate |
| `timed_out` | `timed_out` |
| `not_run` | `not_run` |
| `failed`: a hard limit broken or a wrong answer | `failed` |

It declares no offload, so its cells never move to a TCG host. It runs
as a change's suite when the change touches what CLAUDE.md's "Latency is
UX" lists. A passing suite says that every benchmark ran and gave right
answers; it is not the before and after numbers that rule asks for.
Those are its comparison, which the report prints for every cell against
the newest committed run of the same environment whose source revision
is an ancestor of the candidate's, with no dirty tree. A comparison that
is `inconclusive`, `no baseline` included, does not fail the suite, and
does not supply the numbers either: the change then needs a paired run.

The suite's boots go through the gate's store of passing boots
([design-build.md, Reusing passing boots](design-build.md#reusing-passing-boots)),
whose key holds the image, QEMU's arguments, QEMU itself and the tools'
code. An unchanged image costs nothing: the stored log is judged again,
its numbers stand as the measurement of the run that recorded them, the
report names that run, and the writer adds no record. A replayed log is
historical evidence only ([Comparison](#comparison)). A store belongs to
one host, so a replayed measurement is always this host's.

Two runs on one host disturb each other. The gate runs its suites one
after another, and the record keeps the host's load; another worktree's
gate running meanwhile shows as load, and makes the comparison
inconclusive rather than wrong.

## Running on the Raspberry Pi 4

FD32's decision needs twenty boots of `nullcall` on the board, ten of each
build, and the interrupt measurement twelve, the six load cells for each
responder; every number of the `pi4-4gb-erxos` environment comes from
boots like these. The board has no rig: nothing on the desk cuts its
power, so a board that halts or hangs stays that way until its power is
cycled by hand. A native bench image has no shell, so nothing but the
image's own end can make the board boot anything after it. The board
boots each build over the network, from a signed image the development
host serves over HTTP
([design-platforms.md, Netbooting from a Mac](design-platforms.md#netbooting-from-a-mac)).

### What the code does today

* **No board build of a bench image.** `NativeBench::Run` takes a
  `platform:` only to link the root task (`NativeRoot`), and always boots
  QEMU (`tools/lib/erx/native_bench.rb`, `Run#boot`). `BootImage#build`
  packs the main Fiasco build's first stage, `Fiasco#image_path`, whatever
  the platform (`tools/lib/erx/boot_image.rb:48`). Only the production
  image packs a board's own first stage (`Fiasco#build_for` and
  `#first_stage_path`, `production_image.rb:507` and `:695`) and checks the
  single file against the board's RAM and device tree
  (`Machine#check_single_file`, `:697`). A test root's place is already the
  development machine's: `NativeRoot.development_place`, 64 MiB into RAM,
  which `Machine.development` also takes.
* **The bench root ends with a reset.** Its done, its deadline and every
  setup failure end through one funnel with
  `erx_fiasco_end(ERX_FIASCO_END_ASKED_RESET, NULL)` (`end_with`,
  `test/guest/native_bench/guest.c`), the board's PSCI reset, never with
  the power-off that leaves the board halted
  ([design-fiasco.md, The Raspberry Pi 4](design-fiasco.md#the-raspberry-pi-4)).
* **Every boot names its archive, and only that.** Fiasco's banner prints
  `erx: boot image build B index I flags ... bootargs N` from the handoff
  page on every boot of every image, before any root runs
  (`Erx_handoff::banner`, `fiasco/kernel/src/erx/erx_handoff.cpp:52-59`),
  and `boot_image_check.rb` matches that line against `BootImage::Built`,
  whose build and index hash are the archive header's
  (`boot_image.rb:50-52`). The first stage `BootFile` puts before the
  archive (`boot_file.rb:78`), and the firmware, BL31 and `config.txt`
  beside the image, are not in what it names, and two boots of one image
  print the same line.
* **The bench root's lines name their boot.** The handoff carries
  `/chosen/bootargs`, `erx_boot_args_parse` takes `erx.arg=WORD`
  (`liberx/backend/fiasco/boot_args.h`), and the bench root takes its first
  such word as its boot's name (`read_name`, `guest.c`), as
  the boot name ([The bench image's boot set](#the-bench-images-boot-set)) says.
* **The stagers serve one build each.** `Netboot.stage` copies a boot
  partition's listed files into a fresh sibling of the TFTP root, checks
  each copy's SHA-256 against the build record, points the root, a
  symbolic link, at the sibling in one rename, and removes every other
  sibling of its naming, the build it replaced included
  (`tools/lib/erx/netboot.rb:79-98`). The board's EEPROM as configured on
  the desk boots over HTTP instead, with no TFTP entry in its boot order
  (`BOOT_ORDER=0xf17`: HTTP, then the card, then a restart): a FAT image
  `boot.img` and its `boot.sig`, an RSA-2048 signature by a key whose
  public half the EEPROM holds, fetched signature first
  (`STEPS.txt`). Scripts outside the tree make and serve them
  ([References](#references)). The stager reads the key with no check
  but its size (`pi4_http_stage.rb:79`) and renames `boot.img` and then
  `boot.sig` into the served directory (`:88-89`), so a download between
  the two renames gets one build's signature and the other's image. The
  server resolves its directory once, at its start, and serves every
  regular file in it whose name fits its grammar (`pi4_http_serve.rb:29`
  and `:76-84`), whatever the file is.
  `Netboot`'s HTTP form and `tools/erx netboot serve` replace both
  ([The network boot the stager drives](#the-network-boot-the-stager-drives)).
* **Cycles are never measured.** The guest prints `cycles_per_tick` as
  `unknown` on every boot (`bench_print_clock`, `guest.c:205`). The Fiasco
  build sets `CONFIG_PERF_CNT_USER` (`config/fiasco/kernel.defconfig:17`),
  under which Fiasco turns the cycle counter on and opens the performance
  monitor to user mode on every CPU it starts (`Perf_cnt::init_cpu`,
  `fiasco/kernel/src/kern/arm/perf_cnt-arm.cpp:211-228`); whether the
  firmware's levels above the kernel leave that read untrapped on the
  board is unverified.
* **No reader of a board's console.** `tools/erx bench import` does not
  exist, and nothing on the host reads the board's console while it runs.

### The construction: the server hands out a queue

A **boot set** is a complete directory of boot files, the files a boot
partition holds, with their SHA-256 in its build record
([The bench image's boot set](#the-bench-images-boot-set)). An **entry**
is one signed boot image made from one set: the set's files, each
checked against its record, and a `cmdline.txt` that ends with
`erx.arg=NAME`, where NAME, the entry's **boot name**, is thirty-two
hexadecimal digits the host draws at random for that entry alone. A
**queue** is a directory of entries numbered from 1.

The boot server serves a queue by one rule: **the n-th download takes
entry n, and every download after the last entry takes the last.** A
download is the bootloader's request for `boot.sig` and its request for
`boot.img` that follows; the server opens both files of one entry at the
first and answers the second from what it opened, and moves to the next
entry once an entry's image has gone out whole. The server answers no
other name. A staged build is a queue of one entry
([design-platforms.md, The HTTP form](design-platforms.md#the-http-form)).

A **board run** serves a queue whose entries are its bench boots and
whose last entry is the pair the server served when the run began,
copied byte for byte: the **found pair**. Two facts carry the walk:

1. **Every bench boot ends with a reset**, so the board downloads again.
2. **Every bench boot names itself.** The bench root prints its boot
   name once it is up, after every report and as its last line
   ([The boot name](#the-bench-images-boot-set)).

The host changes nothing while the board walks: it points the served
link at the queue once, at the start, and back at what it named once, at
the end. Each requirement follows:

* **Runs.** N runs of one image are N entries of its set, each with a
  name of its own.
* **Paired runs.** `A B A B A B`, then the found pair: the paired
  comparison of [Comparison](#comparison) on the board, FD32's twenty
  boots among them. As for `--paired`, the developer builds the two sets
  (`--set DIR`), and the tool builds only the default one.
* **The way back.** The download after the last bench boot takes the
  found pair, so that boot's reset boots the build the board was found
  with, or, when no pair was served, the card the bootloader falls back
  to.
* **No download meets a change.** A download is bound to one entry at its
  first request, so a change of the served link at any moment (the
  walk's two, an interrupted run's, a stalled host's) gives each download
  one entry's image with that entry's signature.
* **Every line belongs to the boot that wrote it.** Each bench entry goes
  out whole at most once, so a boot name names at most one boot. The
  console keeps the order in which the board wrote, so a line that lies
  between two lines naming one boot was written by that boot, whatever
  was lost around it; a line between two different names, before the
  first or after the last, belongs to no boot and is kept only in the
  log. The `WINDOW` lines a test task writes carry no name and are placed
  the same way. A lost line costs at most its cell, and a lost naming
  line the lines it brackets; no line is ever judged with another boot's.
* **A name names the whole set.** The bootloader loads `boot.img` whole
  as a RAM disk, and the firmware reads every boot file from it
  (`STEPS.txt` and `pi4_http_stage.rb`'s RAM disk limit; the firmware's
  own documentation is unverified here): `cmdline.txt` with the firmware
  files, `config.txt`, BL31 and the bench image. So a boot that prints
  entry k's name ran entry k's whole set, two sets that share a bench
  image and differ in firmware or `config.txt` are told apart, and the
  record's firmware hashes are those of the set the entry was made from.
* **Signing covers the network boot only.** The signature says which
  image a network boot loaded. The card the bootloader falls back to is
  not signed (`BootPartition.plan` lays out ordinary boot files, no
  `boot.img` or `boot.sig`), so a boot is the queue's only when it prints
  an entry's name, and a banner is never taken as proof of what booted.

The host reads the console itself and writes every byte to the run's log
as it arrives. The walk's decisions depend only on the naming lines, the
end lines, the return's banner and the deadlines below; the record is
made afterwards from that log and the walk's own outcomes by the one
reader of board logs, the one `bench import` uses.

### The bench image's boot set

The board's set is the native bench image built for the board and laid
out as the production image's boot partition is:

* **The image.** `BootImage` takes the platform: Fiasco is built for it
  (`Fiasco#build_for`), the single file starts with its first stage
  (`Fiasco#first_stage_path`), and it is checked against the board's RAM
  and device tree by `Machine.development(platform).check_single_file`
  at that stage's address (`Fiasco#first_stage_address`), as the
  production image's is. For QEMU `virt` the first stage is the main
  build's, so QEMU's bench images do not change. The root is linked at
  the development place, as on QEMU, and with the profile form's sizes.
  Every board set also packs `native_task`'s program, which the cycle
  probe runs ([The cycle counter](#the-cycle-counter)).
* **The set.** `BootPartition` writes the partition's files and their
  build record into `build/bench-board/<benchmark>/` and nothing more:
  `write_set`, which places the files and writes the record through the
  one staging step `write` uses, without the data volume, `PiMedium.write`
  or `compress`, as `boot.receipt.json` beside `boot/`; `lay_out_set`
  shares the plan and the record (`layout`) with `lay_out`, which formats
  the volume and makes the card. Each distinct set is laid out once, and every
  entry of it is made from that one layout. The firmware and
  `config.txt` are those the normal image's set has, from the same
  platform record and pins, so the bench runs at the board's own
  settings.
* **The CPUs.** The count is the platform record's `cpuset`; the pair a
  two-CPU cell spans is the root's CPU and the last, as on QEMU
  (`NativeBench.asked`).

**The boot name.** The bench root takes its first `erx.arg` word as its
boot's name, thirty-two lowercase hexadecimal digits, and prints
`erx: bench: boot NAME` once it is up, before the cycle probe and its
cells, and after each `BENCH` and `CLOCK` line; it prints
`erx: bench: boot NAME done` at its done and
`erx: bench: boot NAME deadline` at its deadline, and QEMU's `bench-done`
checkpoint (`NativeBench.checkpoints`) takes those last two. Every line the
root prints for a person, the cycle probe's among them, so falls between
two naming lines. A boot with no such word prints
`erx: bench: no boot name` and ends before any cell. An
entry's `cmdline.txt` is its set's line followed by ` erx.arg=NAME`, or
that word alone when the set has none, with no newline after it
([design-fiasco.md, The command line](design-fiasco.md#the-command-line)).
Under QEMU, where each boot has a console of its own and reuse keys a
boot by its command line ([design-build.md](design-build.md#reusing-passing-boots)),
`NativeBench` passes `erx.arg=` with thirty-two zeros, and the judge
reads the boot's lines as it does today.

**The end.** Every end of the bench root, its done and its setup
failures, is the machine's end with a reset:
`erx_fiasco_end(ERX_FIASCO_END_ASKED_RESET, NULL)`, whose last line is
`erx: end reset` ([design-fiasco.md, The end path](design-fiasco.md#the-end-path)).
That is the seam: the same end `reboot` asks of the running system
(`ERX_END_RESET`), which on Fiasco reaches its platform control and, on
the Pi 4, the firmware's PSCI system reset, which BL31 makes with the
board's power-management watchdog; the bench root never touches the
watchdog's registers. Under QEMU's `-no-reboot` every end exits QEMU, so
a QEMU boot differs only by its last line. Every boot's judge reads that
line: a board boot that ends `erx: end off` has halted the board, and the
run says its power needs cycling.

**The guest's deadline.** Before its cells the bench root starts one
thread of its own, at the root's band as every thread of the root runs
(the backend refuses `erx_thread_set_urgency`, [above](#what-the-existing-tools-do)),
that sleeps until the boot's deadline. A cell that spins on its CPU
shares that CPU with it at the slice's end, so the thread runs within a slice of its deadline;
a cell running at the band's ceiling, which would keep it from running,
is not a case the bench has. If the cells have not finished by then it prints
`erx: bench: boot NAME deadline` and ends the machine with a reset;
whichever of it and the done path ends first takes the end path's one
caller. Every cell the boot did not report is `timed_out`, as at a QEMU
deadline. Every cell it did report is `rejected`, since a boot's `CLOCK`
line follows its cells (`wake.c:425-433`) and a boot without one has no
calibration (`BenchMeasurement.boot`, `bench_measurement.rb:159-178`),
unless it failed on a result the clock does not judge; keeping such
cells would need a calibration of their own, which no consumer asks
for. The deadline is one number per profile form, kept in `NativeBench`
beside the profile sizes and compiled into the root by flag; QEMU's
deadline for the boot is that number plus a margin, so on both a hung
cell is ended by the guest first. The thread sleeps through the cells
and never runs while they do.

### The cycle counter

The run tests the read rather than assume it. On a board set, before its
cells, the root launches `native_task`'s program as a disposable test task
in a mode of its own, `MODE_CYCLES`, on the root's CPU: the task reads the
cycle counter and the system counter, spins one second by the system
counter, reads both again, and exits with the cycles per tick in
thousandths, as `MODE_TURNS` exits with its median. The read is one
accessor beside `erx_fiasco_counter` in the backend's architecture layer
(`liberx/backend/fiasco/arch/aarch64/clock.c`, the file the inline
assembly chokepoint already lists for the counter).

| What the task does | What the `CLOCK` line carries |
| --- | --- |
| exits with a positive count | the count, as `cycles_per_tick` |
| faults on the read, which ends it with a fault record as `vm`'s disposable task's write does | `unknown`; the root prints `erx: bench: cycle counter: not readable in user mode` |
| exits with 0: the counter did not advance | `unknown`; the root prints `erx: bench: cycle counter: did not advance` |

The root's line is for a person reading the log; the host reads only the
`CLOCK` line. QEMU's sets do not run the probe: a cycle counter under an
emulator or a hypervisor counts what QEMU or the host makes of it, not
the host CPU's cycles, so their `CLOCK` lines stay `unknown`.

### The walk

`tools/erx bench NAME --env pi4-4gb-erxos --console DEVICE --ssh DEST
--key FILE [--runs N] [--profile full] [--set DIR ...]` runs it:

1. **Before anything is served**, every refusal of
   [Refusals and error results](#refusals-and-error-results) is checked,
   and the default set is built (or each `--set` read). The run takes the
   stager's lock, which it holds to the end, and only then reads the
   **found target**: the directory the served link names, or none. It
   prepares the queue as one fresh sibling of the link
   (`Netboot.prepare`): each distinct set copied once and checked against
   its record, each entry's image made and signed, and the last entry the
   found target's last pair, copied and compared by SHA-256, or an entry
   with no pair when the found target holds no whole pair. It writes the
   queue's file beside the log ([Importing a log](#importing-a-log)). The
   found target is only read. Its **return identity**, the build and
   index hash of its set's `kernel8.img`, is read when the found target is
   a stage `Netboot` made, and is unknown otherwise.
2. It opens the console device, 115,200 baud, and starts the log. Over
   ssh it reads `/proc/sensors/status`
   ([design-board-sensors.md](design-board-sensors.md#procsensors-and-the-inspector)):
   the SoC temperature, the throttle state and the ARM clock before the
   run, `unknown` where the path is unsupported.
3. It points the link at the queue (`Netboot.point`) and asks the running
   system to reboot: `ssh -T -- DEST reboot`, which root's session may
   run, since it holds the `machine` grant
   (`config/manifest/development.txt`, `facet machine`). The destination
   is checked as `CodeSsh` checks it. If ssh fails, the run says so, asks
   for a reset by hand, and waits the boot deadline.
4. **Each line it reads** goes to `BoardWalk`, a pure function of the
   queue's names, the found pair's return identity, the walk's state and
   the line's kind, which answers what the line means for the walk:

   | The walk reads | It does |
   | --- | --- |
   | the first line naming an entry after the last one begun | that entry has begun, and its end deadline starts; the one begun before it, if it had not ended, ended unseen, and each entry between that never began, sent with no boot seen, is `not_run` |
   | a `done` or `deadline` line naming the entry that has begun | the entry has ended; the boot deadline starts for the next one, or for the return after the last |
   | a line naming an entry that has ended, or no entry of the queue | the walk ends: the board booted an entry again, which only a restarted server can make it do |
   | `erx: end off` | the walk ends: the board has halted, and its power needs cycling |
   | a banner after the last entry has ended | the return: `booted` when it names the return identity, `unexpected` when it names another build, `unknown` when the identity is unknown |
   | the end deadline passing | the entry's unreported cells are `timed_out`; the walk ends: the board hangs below the bench root, and its power needs cycling |
   | the boot deadline passing | the walk ends: no line of the next entry came. A banner read meanwhile says what the board did: one of the next entry's set, a hang below the bench root, whose power needs cycling; one of another build, what the board runs instead, such as the card it fell back to, which runs until it is reset |
   | the return deadline passing | the return is `not_seen` |
   | a boot's bytes over their limit, the console closing, or an interruption | the walk ends, saying which |

   When the walk ends early, the entries not begun are `not_run`, and the
   link is pointed back at once, so the board's next download, after the
   reset its boot makes or the power cycle the run asks for, takes the
   found target's pair.
5. **Three deadlines and a byte limit** bound the walk, each deadline a
   starting value revised from the first runs' recorded times: the boot
   deadline, 180 s from the reboot request or an entry's end to the next
   entry's first naming line; the end deadline, the guest's deadline plus
   60 s from an entry's first naming line to its `done` or `deadline`
   line; and the return deadline, one boot deadline from the last
   entry's end to a banner. Each starts at most once per entry and the
   walk only moves forward, so a run lasts at most the queue's length
   times the boot and end deadlines, plus the return's, whatever the board
   prints. Each boot's bytes, from the end of the entry before, are
   bounded as they are read by the record's limit on a boot's log, 64 MiB
   (`BenchRecord::LOG_BYTES`, `bench_record.rb:37`), not only when the
   record is written; a line longer than a `BENCH` line's 64 KiB is cut
   there and refused, and the rest of it, to its newline, goes to the log
   alone.
6. **At the end** it points the link back at the found target, or removes
   the link when there was none, and removes the queue; reads
   `/proc/sensors/status` again once ssh answers; and writes the record
   from the log and the walk's outcomes. A failed point back is said with
   the found target's path and the command that restores it, and the
   queue is left in place: the link still names it, and its last entry
   is the found pair.

**The pieces.** `Netboot`'s HTTP form has two steps:
`prepare(root:, sets:, names:, key:, found:)` writes a queue as a fresh sibling
of the served link, and `point(root:, target:)` renames the link, where
`target` is a sibling, the found target or none (the link removed);
`found` is the found target as `Netboot.found` reads it, or none for a
stage, whose queue has no way back. Its
`stage` is `prepare` of a one-entry queue, `point`, and the removal of
stale siblings; a board run calls the first two under the lock it holds.
The boot server's decision is pure: the request `Web::Http.read` gives,
the link's target, the cursor and the download in progress, to the
answer and the next state ([design-platforms.md, The HTTP form](design-platforms.md#the-http-form)).
`BoardWalk` and `BoardLog` are pure and tested on the host;
`BoardConsole` opens the device, sets its line, and appends what it reads
to the log, yielding each line, at most a `BENCH` line's 64 KiB and its
end, to the walk. Nothing else is new: the image is `BootImage`'s, the
set `BootPartition`'s, the judge `BenchMeasurement`'s and the writer
`BenchRecord`'s. Every byte of the board's that the run shows, in its
own diagnostics or from ssh, reaches the terminal only through
`LineEscape`, and nothing the board prints names a path, a command or a
signing input: a boot name only selects an entry the host prepared.

### The record of a board run

The record is the one of [The record](#the-record), in
`bench/pi4-4gb-erxos/<run>/`, one per subject, so a paired walk writes
one for each set and a comparison:

* **environment**: kind `pi4`, system `erxos`, four CPUs and 4,096 MiB,
  and the SHA-256 of every firmware file from the build record of the
  set the record is of;
* **subject**: the source revision, the SHA-256 of the set's
  `kernel8.img` and of its build record, the root's flags and the
  compiler;
* **run**: the sensor readings before the run and after the return, each
  named for when it was read; each entry's name, position in the queue
  and `boot.img` SHA-256, and the walk's outcome for it; how the walk
  ended; and two facts kept apart: `restored`, whether the link named the
  found target again at the run's end (on the host), and `returned`,
  what the board booted after the last entry (`booted`, `unexpected`
  with the banner's build and index hash, `unknown` or `not_seen`);
* **boots**: `boot-<n>.serial.log` is the console from the end of the
  entry before it, or the run's start, to the end of the entry's own last
  line and the `erx: end` line after it, so the bootloader's and the
  firmware's lines stay in the log of the boot that follows them; the
  bytes after the last entry, the return among them, end the last
  entry's log.

### Importing a log

`tools/erx bench import NAME --env pi4-4gb-erxos --queue FILE [--profile
P] LOG` makes the record of a walk from its log, when the walk's own
record was not written (a history root refused, a host that died). The
queue's file, `queue.json`, which the walk writes beside its log under
`build/bench-board/` before it serves the queue, names each entry's
name, its position and the set it was made from, and the found pair's
return identity; the walk's outcomes, `walk.json`, are written beside it
as the walk ends. A log of boots that print no names has nothing that
ties a line to a boot, and is refused.

The reader is `BoardLog`, a pure function of the log's bytes, the queue,
the sets' asked cells and the walk's outcomes when it has them. It
places each line by the rule of
[the construction](#the-construction-the-server-hands-out-a-queue): a
line naming an entry, and every line between two lines naming the same
entry, belong to that entry's boot; any other line belongs to none. A
name is exactly thirty-two lowercase hexadecimal digits and a banner's
build and index hash exactly 16 and 64, the handoff's sizes. Each
entry's `BENCH`, `CLOCK` and `WINDOW` lines go to `BenchMeasurement.boot`
against what `NAME` asks at profile `P`, as a QEMU boot's lines do: as
timed out when the entry printed its `deadline` line or the walk's end
deadline passed in it. An entry that printed neither `done` nor
`deadline` has its unreported cells `not_run` with the walk's reason
when the walk gave one (an interruption, a closed console), and
otherwise with `the log ends before its boot did` or `its boot's end was
not seen`, never `timed_out`, which only a deadline someone saw says.
An entry whose lines lie on both sides of another entry's line booted
twice, and all its cells are `rejected`. The live run's record is the
same function of the log it captured. Every byte the reader takes is
the board's, untrusted: nothing it reads reaches the terminal but
through `LineEscape`, and the reader is fuzzed with the bench lines'
reader.

## Other systems on the same Raspberry Pi 4

A comparison across systems is only as fair as its board. Every system
runs on the same 4 GB Raspberry Pi 4, in the same case and cooling, from
the same power supply, with the same `config.txt` frequency settings, and
starts each run after a minute idle. Each record keeps the firmware files'
SHA-256 (each system's image ships its own copy), and the temperature and
throttle state where the system can read them; a difference is recorded,
not corrected.

| System | Version | How it boots | What it runs |
| --- | --- | --- | --- |
| erXos | the subject | netboot, walked by the board itself ([Running on the Raspberry Pi 4](#running-on-the-raspberry-pi-4)) | the bench images |
| L4Re | a pinned L4Re snapshot of the Fiasco revision erXos's fork came from, built by its own build system, without virtualization support as erXos's fork is | netboot, as erXos's Fiasco does | L4Re's own IPC benchmark (`github.com/l4re/ipcbench`), fetched pinned; in the configuration erXos's fork uses, which is the comparison, and in L4Re's published configuration as a diagnostic: a result more than a tenth from the page's 505, 702 and 305 cycles is reported beside the comparison and looked into, and does not by itself void it |
| FreeBSD | 15.1-RELEASE's image for the Raspberry Pi, the release erXos's commands are compared with in the oracle guest ([design.md](design.md#testing-and-the-oracle)); that it boots this board is unverified | its own SD card | `erx_peer_bench` |
| Linux | Raspberry Pi OS Lite, 64-bit, pinned, with the vendor's stock kernel; its real-time kernel as a second row for `wake` only, if the image offers one (unverified) | its own SD card | `erx_peer_bench` |

Each image is fetched by the fetch step at a pinned URL and SHA-256, and
written to its own card; nothing from it enters the tree, and nothing of
it runs on the host. A system's frequency governor is set to hold the
configured frequency, and how each system is told so is checked on the
board.

`bench/peer/erx_peer_bench.c` is one C17 file under erXos's license that
FreeBSD and Linux compile on the board with their own compiler; the record
keeps the compiler's version and flags. It runs the POSIX counterpart of
each operation and prints the same `BENCH` lines, so one reader imports
all four systems. It reads the system counter directly where the system
lets user mode read it (unverified on both; recorded as clock `counter`),
and otherwise `CLOCK_MONOTONIC` (recorded as such). It pins threads with
`cpuset_setaffinity` on FreeBSD and `sched_setaffinity` on Linux, the one
place it differs by system.

A run of another system on the board writes its console to a file
through the host's serial adapter, and `tools/erx bench import NAME --env
pi4-4gb-SYSTEM LOG [--capture FILE]` turns the log, and the analyser's
capture, into a record; an erXos log goes through the same command with
the queue it was a walk of ([Importing a log](#importing-a-log)). L4Re's
benchmark prints its own format; its importer keeps only what it prints,
so its rows are `partial: mean only` where it gives a mean.

**Counterparts.** Each declaration names, per operation, what the other
systems run, and the side-by-side table prints that line with the numbers:

| erXos operation | L4Re | FreeBSD and Linux | What differs |
| --- | --- | --- | --- |
| `nullcall.kernel` | the null system call | `getppid` | a POSIX call does a little work |
| `nullcall.root-cross-space` | IPC between two tasks | an 8-byte round trip over a pipe between two processes | erXos's number is a decoder-refusal round trip: Fiasco's IPC plus the root service's receive, decode and refusal; how far it differs from L4Re's IPC is read only once ipcbench's direction, payload and statistic are known |
| `vm.commit`, `vm.touch`, `vm.protect`, `vm.decommit`, `vm.map` | none | `mmap` of anonymous memory, the first write to each page, `mprotect`, `madvise` freeing pages, `mmap` of a shared memory object | erXos's calls are requests to the root service on Fiasco, and its commit may map pages at once where POSIX allocates at the first touch; the table therefore also sets allocation plus first touch of a whole range beside each other, the one endpoint both share |
| `wake.park-deadline` | none | `clock_nanosleep` with an absolute deadline, period 1 ms | the systems' timer resolution |
| `wake.wake-cross-cpu` | none | a thread blocked on a condition variable woken from another CPU | the wait primitive |
| `wake.gpio-edge` | none | a process blocked on a GPIO line's event, writing a second line (FreeBSD's `gpioc` events, Linux's GPIO character device; FreeBSD's support on this board is unverified) | all four on the analyser's clock |
| `sched.share-equal` | none | the same spinners, pinned, at the default priority | the scheduler |
| `xdomain.local-rtt`, `xdomain.xdomain-pingpong` | none | a 64-byte round trip over a UNIX-domain socket | a socket is not a connection between domains |

seL4's published numbers stay context: seL4 is not among the systems
approved to boot on the board.

### The interrupt probe

The probe that found the late interrupt timed a path from inside it. Its
complement times the same kind of path from outside, on the analyser's
clock, and so sees what no stamp can: the hardware's delay before the
kernel runs, and an edge the system answered late or not at all.

The analyser, a Glasgow, drives one spare header GPIO into the board, the
*stimulus*, and watches a second, the *response*; the console's GPIO 14
and 15 and the JTAG pins 22 to 27 are not used. The protocol is fixed so
that every response edge belongs to one stimulus:

* the stimulus is a rising edge, followed by a falling edge 100 us later,
  and the next rising edge comes at a random interval of 2 to 20 ms, so
  it is never in step with the 1 ms tick;
* the responder acts on each rising edge it handles by inverting the
  response pin once, so its k-th response edge answers the k-th
  stimulus;
* a capture begins only when the responder is ready: it has been
  started afresh, has cleared the GPIO bank's event status for its pin
  and acknowledged its line, so no old event is pending, and has printed
  `ready` on the console; the analyser starts the stimulus only after
  that line;
* a stimulus whose response edge has not come before the next rising
  edge ends the capture: matching stops there for the rest of the
  capture, what came before stands, and the cell is `partial` with the
  stimulus's number and a lower bound on its latency (the gap to the next
  stimulus). Another capture starts only by the same sequence: stimulus
  stopped, responder restarted, its `ready` seen. Silence on the pins
  never resumes matching.

The interval from a stimulus's rising edge to its response edge is one
sample of `wake.gpio-edge`, on the analyser's clock, for every system
alike; the record keeps the analyser's sample rate, since each edge is
known to within one sample period. Two responders run on erXos, each in
its own boot and alone on the line and the GPIO page while it runs: a
native holder task, as `native_irq`'s holder is, which times the kernel
and the native path, and a `high` Erlang process attached to the GPIO
bank's line through `erx_irq_line`, which times the path the console
driver's process takes. Both need the GPIO unit's page and line 145,
which the development manifest places in the system domain
([design-header-io.md](design-header-io.md#placement-units-and-domains));
whether the system domain's runtime can reach that page through the
device NIF is unverified, and if it cannot, the Erlang responder waits
for the GPIO driver. Each of the Fiasco design's six load cells runs
with each responder. The bench images are marked as test images and
checked by the manifest's own authority checks; the probe needs no
privilege of its own.

## The first five benchmarks

IPC, the scheduler and memory come first. The order follows the failures
each catches, most damaging first. Each has cells in the landing matrix
([The gates](#the-gates)), and its full form runs at the gates that name
it.

### 1. `wake`: how late a waiting thread runs

| Operation | Exact act | Correct result | Profile |
| --- | --- | --- | --- |
| `park-deadline` | an executor of the root's group parks with deadline k of the phase sweep ([Profiles](#profiles)) and stamps its return | `ERX_ETIMEDOUT`, not before its deadline | periodic, on the root service's CPU and on another |
| `wake-same-cpu`, `wake-cross-cpu` | thread B parks with a deadline 1 s away; thread A, on B's CPU or another, sees B parked (`native_irq`'s handshake), stamps, calls `erx_executor_wake` for B's slot, and blocks; B stamps its return | B's park returns `ERX_OK`; a return of `ERX_ETIMEDOUT` is a lost wake | fast |
| `trigger-take` | a thread stamps and fires a doorbell bound to the root's group with `erx_irq_trigger`; the parked executor's take returns its label and it stamps | the label the bind gave, once per fire | fast, same CPU and across CPUs |
| `erlang-timer` | in an image with ERTS (the `xdomain` bench image at the landing gate), a process at `normal` and one at `high` each take a timer with an absolute deadline every millisecond (`erlang:start_timer/4` with `{abs, true}`) and stamp its message's receipt; ERTS's absolute deadlines are whole milliseconds, so this cell takes no phase sweep (`sweep: false`) and its lateness includes ERTS's own rounding; a message more than 1 s past its deadline is a lost wake | one message per deadline, none before it | periodic, placement `runtime` |
| `gpio-edge` | the analyser's stimulus edge to the responder's response edge | a response for every stimulus | periodic, the Raspberry Pi 4 only |

Load cells: idle; a spinner of a test task in the app band on the waiting
thread's CPU; on the board, the six cells of
[design-fiasco.md, Verification](design-fiasco.md#verification). The
landing matrix runs `wake` idle only; its loaded cells are in the full
matrix ([The gates](#the-gates)).

**What it catches.** A lost wake, the one limit that holds everywhere; a
wake that waits behind other work at its level, the late interrupt;
whether a timed wait ends only at a tick, which the phase sweep shows;
and a doorbell path that grows
a request to the root, which `trigger-take` shows as a jump of one root
round trip. `trigger-take` under HVF, on one CPU and across CPUs, settles
the watch list's item on a doorbell from ring to wake.

**What it needs.** A native bench guest, `test/guest/native_bench/`,
whose root reuses `native_irq`'s park handshake and holder, and, for the
full matrix's loaded cells, launches `native_task`'s program
(`test/guest/native_task/program.c`) for their spinners; the guest C library of
`test/guest/bench/` (calibration, histogram, the `BENCH` line); an
Erlang module `bench/erx_wake_bench.erl` typed into the image's shell
as `g3` types its beam; the responders and the analyser's
importer for `gpio-edge`; and the native bench image's boot set for the
Raspberry Pi 4 ([The bench image's boot set](#the-bench-images-boot-set)).

### 2. `sched`: how a CPU is shared

| Operation | Exact act | Correct result | Profile |
| --- | --- | --- | --- |
| `share-equal` | N recording spinners ([A sustained cell](#a-sustained-cell)), N = 2 and 4, of one test task in the app band, pinned to the last CPU, which is not the root service's | every thread runs in each window | sustained |
| `share-tasks` | one recording spinner of test task A, beside the four spinners of test task B, which record nothing, both in the app band, on the last CPU | the same | sustained |
| `band-work` | the root's thread, at its band's base, does a fixed piece of work alone and beside app-band spinners on its CPU, as `native_task`'s band case does; the operation is the work's time | the work finishes | expensive |

Load cells: idle; and `task-spinners`, the four spinners of a second
test task in the app band on the cell's CPU, running before the cell's
own threads start and stopped only after they end, so they are the
background of every window. `share-tasks` runs under `task-spinners`,
`band-work` at both.

**What a window shows.** With N threads at one level, each has a share
of about 1/N, and its longest gap is about N - 1 turns. A turn is the
slice, 1 ms, ended at the first tick after it runs out
([design-fiasco.md, Scheduling](design-fiasco.md#scheduling)), so on a
1 ms tick it lasts up to two ticks. Task A's one thread in `share-tasks`
gets about a fifth, and its longest gap is about four turns: Fiasco
shares a level among threads, whichever task holds them, the limitation
[design-fiasco.md, Bands](design-fiasco.md#bands) records, measured and
not judged.

**What it catches.** A slice that reverts to Fiasco's 10 ms default, a
thread starved at its level, and a band that no longer protects the work
above it. Fiasco gives a thread whose quantum is 0 its default slice
(`Sched_context::set`, `src/kern/sched_context-fixed_prio.cpp:198-200`
and `:212-214`), which is `CONFIG_SCHED_DEF_TIME_SLICE` ticks of
`CONFIG_SCHED_GRANULARITY` microseconds (`src/kern/config.cpp:153-154`),
by default 10 ticks of 1,000 us (`src/Kconfig:353-367`) under the
fixed-priority scheduler, Kconfig's default (`src/Kconfig:327-329`);
`config/fiasco/kernel.defconfig` sets none of the three, so the default
is 10 ms. A thread given its task row's slice, which is 0, takes it, and
the longest gap grows to at least N - 1 such turns.

**How the bench root runs them.** The native bench image packs
`native_task`'s program at `boot/native-task`, as the second-task suite
does. After the wake cells, the root runs the sched cells its build asks
for, one after another; a sustained cell reads its counter on one CPU
and needs no calibration.

* `share-equal`: the root launches the program with
  `SHARE_ARGUMENT(N, cpus - 1, W, window_ms)`, at the landing form
  `SHARE_ARGUMENT(4, cpus - 1, 3, 1000)`, joins it as the second-task
  suite's `case_ends` does, and prints the cell's `BENCH` line.
* `share-tasks`: the root launches task B in `MODE_SPIN`, which takes
  its CPU above the mode byte as `MODE_SHARE` takes its parameters,
  waits until B's four threads are live, as the band case does, launches
  task A with `SHARE_ARGUMENT(1, cpus - 1, W, window_ms)`, joins A,
  stops and joins B, and prints A's `BENCH` line. A task B that does not
  come up, stop or join fails the cell.
* `band-work`: the root times its work alone and then beside task B's
  spinners on its own CPU, as `case_band` does, and prints one `BENCH`
  line for each load.
* On a machine with one CPU the last CPU is the root service's, and the
  two sustained cells are `unsupported: the machine has one CPU`, as
  `wake-cross-cpu` is.

`tools/lib/erx/benches/sched.rb` declares the three operations with their
profiles and correct results; the landing cell, `share-equal` at load
`idle`, placement `other-cpu`, parameters `threads` 4 and `window-ms`
1,000; the full matrix's cells, `share-equal` with `threads` 2 and 4,
`share-tasks` with `threads` 1 at load `task-spinners`, each at
`window-ms` 10,000, and `band-work` at `idle` and `task-spinners`,
placement `service-cpu`; and the counterpart of
[Other systems](#other-systems-on-the-same-raspberry-pi-4).

**What it needs.** `native_task`'s `MODE_SHARE`, writing `WINDOW` lines,
and `MODE_SPIN` taking its CPU; the window accounting in the guest bench
library; `boot/native-task` in the native bench image; and the native
bench guest of `wake`. The second-task suite's share case reads its
task's `WINDOW` lines through the same reader, held to the sizes that
case asks for.

### 3. `nullcall`: the decoder-refusal round trip

| Operation | Exact act | Correct result | Profile |
| --- | --- | --- | --- |
| `root-same-space` | a thread of the root stamps, sends the root service a request its decoder refuses (a call whose request has more than one word, sent with only the caller's word), and stamps the reply | `ERX_EINVAL` | fast, on the service's CPU and on another |
| `root-cross-space` | the same from a thread of a test task | the same | fast, the same placements |
| `kernel` | the cheapest call Fiasco answers alone, chosen from Fiasco's source when the guest is written and named in the record (a candidate is the invocation of an empty capability slot) | the error Fiasco gives that call | fast |

The request needs no new call in the root service. The decoder refuses a
request whose word count matches no layout before any body runs
(`erx_fiasco_wire_decode`, `liberx/backend/fiasco/service_wire.c`), and
answers it through the same receive and reply as every request
(`service_message`, `liberx/backend/fiasco/service.c`). The cell is a
decoder-refusal round trip: the IPC, the receive, the decode and the
reply that every request pays, without the dispatch to a body, which an
accepted request adds. Nothing is added for a benchmark to keep secure.

The stub reports a failed IPC as `ERX_EINVAL` too, so the status alone
does not show that the decoder answered. Each task's row in the root
service counts the messages from it that the decoder refused, from zero
at its start (`erx_fiasco_test_refused`, the test accessor beside
`erx_fiasco_test_pool_free`, reads it for the root and for a task the
root holds), and every root and task cell checks its own run by it: the
count must rise by exactly the calls the run made, warm-up included, or
the cell is `failed`. The root's count is read on the cell's thread
before and after its run, while the root's other threads make no such
request. The task's starts at zero, and the task makes no request the
decoder refuses but its run's, so the root reads it once the task says,
through the page the root mapped into it, that its run is done, and
before the join that ends the task's row. On erXos's kernel, `kernel` is its
null call, the one the speculation mitigations are priced by
([design-arch-aarch64.md](design-arch-aarch64.md#speculation-mitigations)),
and the root operations go, since there is no root service.

**What it catches.** Growth of the receive, decode and reply path, a
mitigation added to every entry, and Fiasco's IPC slowing under a
configuration change. On the board it is the measurement of
[FD32's decision](#fd32s-decision). Beside L4Re's IPC between two tasks
on the same board, it shows what the root service's refusal path adds to
Fiasco's IPC.

**What it needs.** The native bench guest and its test task
(`test/guest/native_bench/program.c`), which times the request on the
CPU the page the root maps into it names.

### 4. `vm`: what memory costs

Each operation is timed from the benchmark's own test task
(`test/guest/native_bench/vm_task.c`); on Fiasco every call is a request
to the root service, and a touch is a plain write. A status of `ERX_OK`
alone could pass a call that did nothing, so after the cells' timed loops
the task makes, once and untimed, for each call the check `native_memory`'s suite makes for that call
(`test/guest/native_memory/guest.c`): a committed page reads zero, a
written page reads back after a protect to read-only and back, a
decommitted and recommitted page reads zero, and the free page count is
what it was once the range is released. A protect that does nothing
leaves a page writable and its contents whole, which no read can see,
so `protect` also has a check that must fault, as `native_crash`'s
read-only case does (`test/guest/native_crash/guest.c`): a disposable
test task protects a written page to read-only and writes it, and the
root expects that task's fault record at the page's address. A failed
check, or a task that exits without the fault, makes the cell `failed`.

| Operation | Exact act | Correct result | Profile |
| --- | --- | --- | --- |
| `reserve`, `release` | `erx_vm_reserve` of 1 page and of 512 pages; then `erx_vm_release` of it | `ERX_OK`; the free page count unchanged after the release | fast for 1 page, expensive for 512 |
| `commit`, `decommit` | `erx_vm_commit` of 1, 64 and 512 reserved pages; then `erx_vm_decommit` | `ERX_OK`, and the checks above | the same |
| `touch` | the first write to each page of a 64-page commit, one sample per page | the write completes and reads back; the operation's result text states that on Fiasco the commit has mapped the pages already (FD7) | fast |
| `protect` | `erx_space_protect` of 1 and 64 committed pages to read-only and back | `ERX_OK`, and the checks above | fast |
| `map` | `erx_mem_create` of 64 pages, `erx_vm_map` of it at reserved addresses of the caller's own space, then `erx_vm_release` of the range and `erx_cap_close` of the object, each timed | `ERX_OK` throughout | expensive |
| `mem-child` | `erx_mem_child` of a 64-page object | `ERX_OK`; the record says it is an eager copy on Fiasco | expensive |

**What it catches.** A commit or a protect whose plan walks more than it
should (the watch list's 65,500 probes of the loader's window is one), a
page charged or zeroed twice, and the cost the root as pager adds over a
kernel's map. Its counterparts on FreeBSD and Linux are anonymous
`mmap`, first touch, `mprotect` and freeing.

**What it needs.** The benchmark's test task in the native bench image,
which the root loads with a budget large enough for 512 pages; the
native bench guest.

### 5. `xdomain`: one message, one domain to another

This is the round-trip half of E-D1 of
[design-domains.md](design-domains.md#performance), under its name
`xdomain-pingpong`, beside the same exchange inside one domain:

| Operation | Exact act | Correct result | Profile |
| --- | --- | --- | --- |
| `local-rtt` | two processes of one domain: the client stamps, sends `{echo, B}`, B a 64-byte binary, and stamps the reply `{echo, B}` | the reply equals the request | fast, placement `runtime` |
| `xdomain-pingpong` | the same, across a connection, as a request on `erx_echo_test`'s facet in another domain, whose `admit/3` answers `{echo, Term}` with `{echo, Term}`; one request outstanding at a time | the reply equals the request | fast, placement `runtime` |

The fixture sets the limits: the `system_domain` suite's facet rows allow
requests of at most 512 bytes and four in flight
(`tools/lib/erx/system_domain_regrant.rb`, `FACET_LIMITS`), and the echo
service answers every request with one reply. A 64-byte binary encodes
well within 512 bytes, and the record keeps each request's encoded size.
Whether the two runtimes' executors park between round trips is not
observed, so the cell is one round trip as the runtimes schedule it,
with no claim to be the busy case or the parked one; it is set beside
the domains design's 1 us target for busy runtimes, which it does not
establish.

**What it catches.** A funnel, lane or facet change that adds a copy, a
pass or a wake to a small request across domains, against the same
exchange inside one domain.

**What it needs.** An Erlang module `bench/erx_xdomain_bench.erl`; a test
image built from the `system_domain` suite's, which boots `erx_echo_test`
in one domain and grants its facet to a peer and to the system
principal's session (`tools/lib/erx/system_domain_regrant.rb`); the
client runs in a domain the facet is granted to, which this image must
give it. No new facet: the echo service is the test-only one that
exists. The same boot runs `wake`'s `erlang-timer`
(`bench/erx_wake_bench.erl`), under the one `CLOCK` line.

The Erlang guests share `bench/erx_bench_hist.erl`, the twin of the C
guest library. Their clock is `counter`: ERTS's monotonic time in its
native unit, which on erXos is `erx_clock_ns`, the system counter scaled
to nanoseconds (`otp/erts/emulator/sys/erxos/sys_time.c`), so the line's
frequency is 1 GHz while the counter steps at its own rate. A batch
therefore spans 100 steps of the calibration's smallest increment, not
100 ticks, which is the C guests' rule in the counter's own steps. The
`CLOCK` line's rounding of a timed wait is 1 ms, the resolution of
ERTS's timers. No Erlang cell stamps across CPUs, so the line
calibrates no pair and its cycles per tick are `unknown`.

### Next

`lifecycle` follows, with E-D3's `domain-lifecycle` and GP's `spawn`:
`spawn_monitor` to `DOWN`, a program's spawn to its `main`, a domain's
creation to its ready report, and its stop to the last death and the
pool's pages back, stamped by the trace ring's `space_start` and
`space_end` records and the requester's clock. E-D1's
`xdomain-throughput` and E-D4's `xdomain-stall` need what the echo
fixture lacks: frames far over 512 bytes, a sink that acknowledges
batches, a bound on the data outstanding, and for head-of-line blocking
small and large frames sent together. They are designed with G5's runs.
File and pipe I/O come with their owning gates.

## Fixing the existing tools

* **`g3` under TCG reports the guest alone.** `BenchG3.report` asks
  `BenchCompare` for the ratio, and `BenchCompare` refuses TCG against
  native, so the TCG report holds the guest's numbers and, per workload,
  `not comparable: TCG against native`. Under HVF the ratio stays, as the
  side-by-side table G3 needs. [plan.md](plan.md), gate G3, says so.
* **`otp-switch` observes its switches.** Before each yield a process
  writes its own index into a shared `atomics` cell; after the yield it
  reads the cell, and a cell holding the other's index means the other ran:
  one switch observed. The measurement's operations are the switches
  observed, its time per observed switch, and a run in which fewer than
  99% of yields switched is `failed: yields did not alternate`. The
  scheduler budget it serves, a process switch within 1.2 times stock OTP
  ([design.md, Performance](design.md#performance)), then has a number
  that means what it says.
* **Every runner writes through `BenchRecord`.** The `OutputDirectory`
  calls under `build/bench` go, each runner's report becomes a record,
  `net-freebsd`'s `--out` default becomes the history root, and `build/`
  keeps only scratch. The boot benchmark's host-clock checkpoints keep
  their clock, named `host`.

## Concurrency and failure

A native guest that hangs in a cell ends itself at its own deadline
([The guest's deadline](#the-bench-images-boot-set)); one that hangs below
it, and any other guest, is ended at its benchmark's deadline, its QEMU
killed with every child. Either way each cell that did not report is
`timed_out`. A native guest's cells that did report are `rejected`,
since its `CLOCK` line follows its cells and never came, unless a cell
failed on a result the clock does not judge. The record is written however the run ended, so a
failure leaves evidence. A guest's line that fails validation makes its
cell `rejected` and the run goes on. A failed boot in a paired run makes
that pair's verdict `inconclusive`, never a pass.

Two runs never share a run directory: the writer creates it exclusively,
and a second writer for the same name fails. The reader of the history
repository takes no lock and needs none: it reads only committed runs as
baselines, and a run directory is complete once its `run.json` is written,
last, by rename.

A cell whose start and end stamps are read on different CPUs is timed
only after calibration found a non-empty offset interval for those CPUs
narrow enough for it; otherwise the cell reports `unsupported`. A cell
whose two stamps are read on one CPU needs no calibration, wherever its
work ran. In deterministic mode every operation runs on one CPU, so the
cells that place work on two CPUs are expected `unsupported` there.

A sustained cell's task bounds its own wait: its first thread gives up on
a spinner that has not published its last window a fixed patience after
that window's end and ends with its status, which the root reports as
the cell's failure; a task that never ends meets the boot's deadline.
Its `WINDOW` lines need no lock between writers: each fits one task
write, which the root's one service thread writes whole. What else
writes the console meanwhile (the kernel) can still cut a line, which
is then refused, and the cell is `rejected`.

**On the board.** A board run holds the stager's lock from before it
reads the found target to its last `point`, so `tools/erx netboot` and a
second run wait for it, and nothing it prepared or reads changes under
it; it holds the console device exclusively, so a second run's open is
refused. `pi4_http_stage.rb` takes no part in the lock and writes into
whatever directory its `--www` names, a queue's included, so `Netboot`'s
HTTP form replaces it ([Decisions](#the-network-boot-the-stager-drives)).
The walk is one thread over one console; its decisions are `BoardWalk`'s,
and its effects are two renames of the link, the ssh calls and the log.
The boot server answers one connection at a time, so its cursor and the
download in progress have one writer. The boot network holds one board:
a second client's `boot.sig` request would take the board's download
from it, and the board's `boot.img` request would then be answered 404.

* **A hang in a cell** meets the guest's deadline: the boot ends with a
  reset, its unreported cells are `timed_out` and its reported ones
  `rejected`, and the board downloads the next entry.
* **A hang below the bench root**, in Fiasco or in a root whose deadline
  thread cannot run, meets the end deadline: the link is pointed back,
  the record is written, and the run says the board needs its power
  cycled, after which it boots the found target's pair. So does a boot
  that ends `erx: end off`.
* **A board that boots no entry**, because ssh could not ask it to reboot
  and nobody reset it, or because a download failed and the bootloader
  fell back to the card, meets the boot deadline: the link is pointed
  back and the entries not begun are `not_run`. A card's system runs
  until someone resets it, and the record's `returned` says what was
  seen.
* **An interrupted run** (a signal, a failure of the tool) points the link
  back before it exits, at whatever moment that is, and removes the
  queue. A download in progress keeps the entry it was bound to, from
  files the server already holds open, so the board boots one entry or
  the found pair, never a mix.
* **A host that dies** without that step leaves the queue served. The
  board walks the rest of it, each boot ending itself, and rests on its
  last entry, the found pair. The next run refuses a found target that is
  a queue of more than one entry, and the next `tools/erx netboot`
  removes it as a stale sibling.
* **A restarted server** serves the queue from its first entry again. The
  walk ends at the first line naming an entry that has ended, and
  `BoardLog` rejects the cells of an entry that booted twice.
* **Lost console bytes** cost at most a cell: a lost line loses its cell,
  a lost naming line leaves the lines it brackets to no boot, and a lost
  `done` line leaves that boot's end unseen; no line is judged with
  another boot's.
* **A broken console** that prints without end meets the byte limit or
  the deadlines, and one that closes ends the walk; neither keeps the
  host working or holds the lock past the walk's bound.

## Refusals and error results

| Case | Result |
| --- | --- |
| `tools/erx bench NAME` for a name no file declares | refused: `unknown benchmark NAME` |
| an environment the benchmark does not declare | refused, naming the environments it declares |
| a history root that does not exist, is not the top of a git work tree, shares the erXos repository's common git directory or a root commit, or lies inside any of its worktrees | refused before anything runs, naming which |
| a comparison of records whose environments or cells differ (operation, load cell, placement, workload parameters, clock, batch size, profile sizes) | refused, naming the first difference |
| a comparison of TCG or deterministic records with any other kind | refused: `TCG numbers are not compared with HVF or native numbers` |
| a replayed boot offered as a calibration, baseline or paired run | refused: `a replayed log is not a new run` |
| a record that does not parse, or of an older format | refused with the file and the reason |
| a baseline with fewer than three runs, or none | the comparison is `inconclusive`, not an error |
| `--paired` without two images | refused |
| a call that answers `ERX_ENOTSUP` | the cell is `unsupported`, reported by the backend |
| a sustained cell whose `WINDOW` lines are not exactly one for each of its windows and threads, in order | the cell is `rejected`, naming the first missing or misplaced line |
| `WINDOW` lines followed by a `BENCH` line of another profile, or by none | the lines are refused |
| a `measured` sustained cell with a thread that made no pass in a window | the cell is `failed`, naming the thread and the window |
| `--env pi4-4gb-erxos` without `--console DEVICE`, `--ssh DEST` or `--key FILE` | refused before anything is built, naming what is missing |
| a console device that cannot be opened, or that another run holds | refused before anything is served |
| a served path that is neither a symbolic link nor absent, such as the directory `pi4_http_stage.rb` writes | refused, as `tools/erx netboot` refuses it, naming the path |
| a found target that is a queue of more than one entry | refused: `the served link names a queue an earlier run left; stage a build first` |
| a signing key that is not a regular file when opened without following a link, is not the user's own, grants any permission to group or others, or is not RSA-2048 | refused, naming which; no byte of the file is shown |
| an ssh destination that begins with `-` | refused, as `CodeSsh` refuses it |
| a set whose single file the board's RAM and device tree leave no room for | refused when the set is built (`Machine#check_single_file`) |
| an entry's image over the bootloader's RAM disk limit | refused when the entry is made |
| `--runs` below 1, or `--set` with a directory whose build record does not list `kernel8.img` | refused |
| an ssh `reboot` that fails | not a refusal: the run says so, asks for a reset by hand and waits the boot deadline |
| a boot with no `erx.arg` word | the root prints `erx: bench: no boot name` and ends before any cell; on the board no line names the entry, so it meets the boot deadline |
| no line naming the next entry within the boot deadline | the walk ends, the link pointed back; the entries not begun are `not_run` |
| no `done` or `deadline` line within the end deadline, or a boot that ends `erx: end off` | the same, the boot's unreported cells `timed_out`, and the run says the board needs its power cycled |
| a line naming an entry that has ended, or a name of no entry | the walk ends as above: `the board booted an entry again` |
| a boot's bytes over 64 MiB, or the console closing | the walk ends as above, saying which; a line over 64 KiB is refused and the walk goes on |
| a link that cannot be pointed back at the end | not a refusal: the run says so with the found target's path and the command that restores it, `restored` is false, and the queue stays served |
| `bench import` of an erXos log without `--queue` | refused: only the queue's names tie the log's lines to boots |

## Verification

Two kinds of check prove the design's claims, and they are kept apart.

**Correctness tests** are deterministic. The tools' cores are pure Ruby,
and the guest library's schedule and classification of periodic deadlines
are a pure C function of the stamps it is given, built for the host as
the guests' other cores are. Each test pairs a passing case with a seeded
fault that must fail it:

| Test | Passing case | Seeded failure that must fail it |
| --- | --- | --- |
| the writer's destination | a record under a temporary separate repository is written; one inside a second worktree of the erXos repository, a history root that is a symbolic link into the tree, a separate repository whose `bench` directory is a symbolic link into an erXos worktree, and a plain directory that is no git work tree are each refused | the worktree check dropped: the write into the second worktree succeeds; the destination's walk dropped, leaving the root's check: the write through the `bench` link succeeds |
| comparability | a TCG record against a native one is refused, `g3`'s TCG report holds no ratio, and two cells differing only in batch size are refused | the kind check dropped: the report shows a ratio; the batch size left out of the cell: the comparison is made |
| the percentile rule | 1,000 samples give a 99th percentile and 999 do not; 10,000 give a 99.9th and 9,999 do not; 20 give a median and 19 do not | the count test written `>= 9`: 999 samples report a 99th percentile |
| the verdict | three baseline runs and three candidates: within the band is `same`, two of three above it by more than the threshold `slower`, one of three `inconclusive` | one of three accepted as `slower` |
| FD32's predicate | ten runs a side: a patched median inside the unpatched medians' spread carries the patch, one above it does not, one within a bucket of the edge is `inconclusive`, and a single patched run outside the spread with the median inside still carries it | the generic verdict used instead: the single outlying run rejects the patch |
| a replayed log | a replayed boot's numbers appear in the report and are refused as a baseline run | the replay mark ignored: a replayed log counts as a third baseline run |
| the histogram (C and Erlang, on the host) | samples spread over twenty octaves each land in a bucket whose bounds contain them and whose width is at most 1/64 of its lower bound | an off-by-one in the sub-bucket index: a sample lands outside its bucket |
| the `BENCH` line reader | a fuzz target over the line validator, with the guests' own lines as seeds, runs its budget clean | the check that the histogram holds the line's sample count removed: the fuzzer finds an accepted histogram holding more samples than its profile asked for, the bound that also bounds its length |
| the cross-CPU offset | host stamps with a true offset of 50 ticks and every transfer 100 ticks give, with the one-tick widening, the interval `[-51, 151]`: it contains 50, its half-width is 101, a cell with a 1,010-tick median is accepted and one of 1,009 is `unsupported`; stamps whose offset moves by 300 ticks between the calibration before and after give disjoint intervals and the cells are `unsupported`; a round trip stamped on one CPU is never `unsupported` | the ordering test of the stamps used instead of the causal interval: a bound of one tick is reported |
| the offset rounds | two host threads pass the token for two calibrations over one token, B's clock 1 ms ahead of A's: each interval holds the 1 ms | A taking `b` before its round reaches B: round one reads the token's zero and its interval excludes the offset |
| a periodic deadline | the classifier, given the stamps of a 5 ms stall at period 100, reports at least four missed periods and a maximum lateness of at least 5 ms, and given a return 10 us before its deadline, one early return | the next deadline taken from the return: the stall shows as one late period; the early test written `<=` the deadline: an on-time return counts as early |
| the phase sweep | deadlines over 160 periods visit each of the sixteen phases ten times, and a fake timer that fires only on ticks gives a minimum observed lateness that varies across phases by about a tick, with each sample's excess above its phase's minimum reported | the phase term dropped: every deadline has one phase |
| a lost wake | in the guest, the `wake` handshake reports `measured` and no loss | the wake sent to another slot: B's park times out after 1 s and the cell is `failed` |
| `otp-switch` | two yielders on one scheduler observe nearly every yield as a switch | the yield removed: no switch observed, the measurement `failed` |
| `nullcall` | every root and task cell's run answers `ERX_EINVAL` and raises its caller's count of refusals by exactly the calls it made | the requests sent to the `kernel` cell's empty slot instead of the service, from the root and in a second seeded build from the task: the stub still answers `ERX_EINVAL`, the count does not move, and that caller's cells are `failed` for it |
| `vm` | each cell's untimed check passes, and the disposable task's write to its read-only page faults at that address | `erx_space_protect` made to answer `ERX_OK` without calling the service: the task's write succeeds, it exits with no fault, and the cell is `failed` |
| the GPIO probe's matching | the importer, given a capture whose third stimulus has no response before the fourth, ends the cell after the second sample, `partial`, and matches no later edge of that capture | the next response matched to the third stimulus: the cell holds a sample for it |
| the window accounting (C, on the host) | at a 24 MHz counter and a 1,000 us slice, a gap of 0.6 ms is one lost turn whose ticks are added to `waited`, a gap of 0.4 ms is a pass, and a window no read fell in is one gap of its whole length with no pass | the slice taken as ticks without the frequency: the 0.4 ms gap counts as a lost turn |
| a sustained cell | twelve `WINDOW` lines, three windows of four threads, then `share-equal`'s `BENCH` line give a `measured` cell with each thread's share and the longest gap; with one `WINDOW` line dropped the cell is `rejected`, and with a thread making no pass in window 1 it is `failed` | the line count check removed: the cell missing a line is `measured`; the idle-window check removed: the starved cell is `measured` |
| a sustained comparison | three baseline runs whose longest gaps are 4 to 6 ms and three candidates at 30 ms give `slower` | the direction reversed, as for a rate: the verdict is `faster` |
| the interrupt-entry pairing (with the patch) | given receipts and `irq_entry` records, one entry between two receipts makes a sample, and none, two, or a window with a record counted as overwritten makes the receipt `partial` | the window's lower end dropped, pairing each receipt with the latest entry before it: the two-entry case yields a sample |
| the board's set | the `nullcall` set's `kernel8.img` starts with the board's own first stage and boots in QEMU's `raspi4b` model under TCG, as the `raspi4b` suite boots the card, with `erx.arg=` and a name on its command line: the banner names the set's build and index hash, the root's naming lines carry the name, every declared cell reports between two of them, and the last line is `erx: end reset`; the model's numbers are not recorded, since the model is no environment | the main build's first stage packed instead: no banner appears before the boot's deadline; the root built to end with `ASKED_OFF`: the judge refuses the boot's end as `erx: end off` |
| the guest's deadline | a `nullcall` build seeded to spin forever once it has reported its first cell, at a 20 s guest deadline, prints `erx: bench: boot NAME deadline` and `erx: end reset` by itself; the cell it reported is `rejected`, as the boot has no `CLOCK` line, and every later one `timed_out` | the deadline thread not started: QEMU's own deadline ends the boot, no deadline line appears, and the test fails |
| the boot server (its decision, exhaustive over a fake bootloader's requests and the link's changes) | against a queue of three entries, four downloads take entries 1, 2, 3 and 3; a `boot.sig` request repeated before its image takes the same entry; a change of the link between a download's two requests leaves its image that of its signature's entry; a request for any other name, a `private.pem` placed in an entry among them, and a `boot.img` request with no download begun, are 404; and over every sequence of up to eight requests and changes, every image sent whole is that of the signature sent before it | the image opened at its own request: the change between the requests sends entry 2's image after entry 1's signature; the cursor moved at the signature's request: the repeated request skips entry 2; the name check widened to any file name: `private.pem` is served |
| the walk (`BoardWalk`, exhaustive over its closed set of events: a naming line of each entry, a `done` and a `deadline` line, a repeated name, a banner of the found pair and of another build, `erx: end off`, each deadline, the byte limit, the console closing) | `[A, A, A, found]` and `[A, B, A, B, A, B, found]` run each entry in order and end `booted` on the found pair's banner; an entry skipped is `not_run` and the walk goes on; a repeated name ends the walk; and over every sequence of up to eight events the walk ends within the queue's deadlines and points the link back exactly once | the end deadline restarted at every naming line of the entry: a board that prints its name each minute keeps the walk past its bound; the return taken from any banner: another build's banner after the last entry is `booted` |
| the board log (`BoardLog`) | a log of three entries, with the bootloader's and the firmware's lines between them, gives three boots with their cells; a dropout over entry 1's `done` line and entry 2's first naming line leaves entry 2's first cell to no boot, its other cells to entry 2 and entry 1's as they were; a `WINDOW` line between one entry's names is that entry's; a log cut inside entry 3 gives its unreported cells `not_run`, `the log ends before its boot did`, without the walk's outcomes and `timed_out` with its end deadline; the fuzz target of the bench lines' reader takes board logs as seeds and runs its budget clean | lines placed by the nearest naming line before them: entry 2's first cell is judged in entry 1's boot; the cut boot taken as timed out without the walk's outcome: its cells are `timed_out` |
| the queue (`Netboot.prepare` and `point`, HTTP form) | two sets and four entries, the found pair last: each set is copied once, each entry's `boot.img` holds its set's files byte for byte (`FatVolume` reads back `kernel8.img`'s placement and every root file with a short name, `cmdline.txt` among them; the test extracts the rest with fsimg) and a `cmdline.txt` ending ` erx.arg=` and its name, each `boot.sig` verifies against the key's public half, the names differ, and the last entry's pair is the found target's byte for byte; `point` at the queue and back leaves the found target's files unchanged and named by the link | the last entry signed afresh from the found target's set: its `boot.sig` differs from the found one; the found target removed as a stale sibling at `point`, as `stage` removes them: the point back fails |
| the signing key | a mode-0600 regular file of the user signs; the same key through a symbolic link, at mode 0640, and a directory are each refused, naming which, and no refusal holds a byte of the file | the file opened following links: the linked key signs; the permission test dropped: the mode-0640 key signs |
| the cycle counter (on the board) | `cycles_per_tick` times the counter's frequency lies within 2% of the `arm_clock` that `/proc/sensors/status` reported just before the run | the probe built to read the system counter twice instead: the count is 1,000 thousandths and the board check fails |
| the walk on the board | a two-entry `nullcall` run on the desk's board ends with both entries run, `returned` `booted` and `restored` true, which also settles that the bootloader's requests fit `Web::Http`'s subset | the last entry made from the queue's first entry instead of the found pair: the board boots that entry again, and the walk ends on the repeated name |

**Sensitivity runs** check, on a real environment, that a benchmark
moves when the cost it watches moves. They are experiments, not proofs:
each seed reports that it ran (a count of its own executions, printed in
the guest's log and kept in the record), a run whose seed did not report
proves nothing, and a seed that ran and left the verdict `same` sends the
benchmark back to its design rather than letting it land.

| Benchmark | Seed, which reports its executions | Expected change |
| --- | --- | --- |
| `wake` | the doorbell trigger stub made to send a root request, the Fiasco design's own seed for its direct doorbell case | `trigger-take`'s median rises by about one `nullcall` round trip |
| `wake` | the deadline handed to `erx_park` made 1 ms later than the one the cell records | `park-deadline`'s lateness rises by about 1 ms at every phase |
| `sched` | the root giving a thread its task row's slice, the quantum case's seed | the run checks that `share-equal`'s longest gap is, in every window, at least N - 1 times Fiasco's 10 ms default, 30 ms with four spinners, against about N - 1 turns of up to two 1 ms ticks unseeded. The growth is not tenfold: an unseeded turn is rounded up to the tick and a seeded one barely, so under HVF on one CPU, with four spinners, the seeded gaps were 33 to 36 ms against 6 to 12 ms unseeded, about 5.5 times (QEMU `virt`, 24 MHz counter, the second-task suite's share case; host load average 5 to 15; QEMU version and compiler unrecorded). On four CPUs the seeded gap is unmeasured |
| `nullcall` | a 1 us busy wait in the decoder's refusal | the median rises by about 1 us |
| `vm` | the commit body zeroing each page twice | `commit` of 512 pages slower |
| `xdomain` | a 10 us busy wait in the echo facet's `admit/3` | `xdomain-pingpong`'s median rises by about 10 us and `local-rtt`'s does not |
| the board limits | the four seeds of [design-fiasco.md, Verification](design-fiasco.md#verification) | the console or SD receipts pass their limit in the cell that seed names |

## Alternatives considered

* **Keep raw samples and compute everything on the host.** The simplest
  record, and the one the board's 115,200-baud console cannot carry. The
  histograms carry their own bounds, so the host still holds no formula.
* **A test-only null request in the root service.** It would add a call
  to secure and to keep out of release builds, to time a dispatch that a
  refused request skips; the refusal round trip covers the path every
  request pays, and the `vm` cells cover accepted requests.
* **Hard thresholds on every number.** On a shared Mac they would fail on
  the host's noise, and teach everyone to rerun until green. Three limits
  carry a promise; the rest inform.
* **Compare each run with the previous one.** Without a band from several
  runs a difference cannot be told from noise; without pairing, a change
  cannot be told from the host's drift.
* **One comparison rule for FD32 too.** It would quietly change a decision
  already accepted with its own predicate; FD32 keeps that predicate.
* **A benchmark framework apart from the suites.** The QEMU gate already
  has cells, statuses, deadlines, reuse and discovery from files; the
  `bench` suite uses them and adds only the record.
* **cyclictest, lmbench and stress-ng on FreeBSD and Linux.** They are
  GPL and measure their own operations; one small program of erXos's own,
  on both systems, compares like with like and needs no clean room.
* **Starting the board limits at the first user-mode stamp.** The
  analyser's `gpio-edge` would bound the kernel's part separately. It
  changes the accepted definition, which runs from Fiasco's interrupt
  entry, so the stamp is taken there instead.
* **A per-line slot for the interrupt entry's stamp.** It would need a
  publication protocol and a rule pairing its count with deliveries; the
  trace record needs neither.
* **A new Glasgow applet first.** It is Python, out of the tree and
  needing approval; a stock applet that fits needs none.
* **`lifecycle` among the first five.** Its consumers, E-D3 and gate GP,
  come later in the plan than the memory costs `vm` shows.
* **The full matrix at the milestone gate before it is timed.** An
  estimated 35 minutes added to a gate on a guess; the duration is
  measured first.
* **Only the stock kernel, or only a real-time kernel, for Linux.** The
  first omits the configuration the published Pi 4 latencies are of; the
  second compares erXos with a configuration no ordinary installation
  runs, on every row.
* **Pooling the patched runs' samples for FD32.** The accepted predicate
  compares medians of runs with the spread of medians of runs; the same
  kind of number on both sides is the one that is comparable.
* **A power-off at the bench's end, and the hardware watchdog to reset
  the board.** The stand-in root would arm the watchdog, and the host
  would have to put the found target back within its timeout, at most about
  16 s by its 20-bit count of 1/65536 s (`include/erx/core/pm_wdt.h`,
  `kernel/core/pm_wdt.c`);
  the end path's reset reaches the same reset with neither.
* **Changing the served set on each banner.** The host would point the
  link at the next set when a boot's banner named the one served, while
  the board reads no file. A host that stalls past that boot's end makes
  the change during the next download, between its signature and its
  image, and the bootloader refuses the pair and falls back to the card;
  a late or lost banner needs rules of its own. With the queue in the
  server the host changes nothing while the board walks.
* **Naming a boot by its banner.** The banner names the archive, not the
  firmware, BL31 or `config.txt` beside it, and two boots of one image
  print the same one, so a dropout over one boot's end and the next one's
  banner would judge the second boot's lines with the first's.
* **The boot name inside every line.** A `WINDOW` line is written by a
  test task, whose whole argument is one 64-bit word
  (`test/guest/native_task/modes.h`), which a 128-bit name does not fit;
  the root's naming lines on both sides of every report tie the task's
  lines to their boot as surely, and leave every line format as it is.
* **A name the image draws from its own generator.** It is unique only as
  far as the generator is seeded, and it names no entry, so the host
  would still read the banner to learn which set booted.
* **The TFTP form for the walk.** dnsmasq serves files, not a queue, and
  resolves the root afresh at each request, so a boot could read its
  files from two sets; the board on the desk boots over HTTP in any case.
* **Following the log a terminal program writes.** Its writes are
  buffered for an interval of its own (unverified for `screen`), and a
  file another program owns has a start, truncation and rotation the run
  would have to handle; a device the run holds has none.
* **A console reader in the bench image, to take `reboot`.** It would add
  a reader beside the measured cells, and a reboot typed after the cells
  does nothing the image's own reset does not.
* **Arming the hardware watchdog in the bench root,** so that a hang below
  it resets the board by itself: an open decision
  ([Open decisions](#open-decisions)).

## Decisions

Each is a choice the design makes among alternatives; the rejected ones
are in [Alternatives considered](#alternatives-considered).

### The interrupt entry's stamp

The two board limits are defined from Fiasco's interrupt entry. A
development-only Fiasco patch, listed in
[design-fiasco.md](design-fiasco.md#the-releases-fiasco-build), stamps each
entry, writing trace records rather than a slot of its own, under this
contract:

* **What it writes.** At each interrupt entry the kernel writes one
  `irq_entry` record, naming the line, into a ring of `erx_trace_record`
  records for its CPU, stamped with the counter the user-mode accessor
  reads. The layout and the event enum are the ones every trace ring
  uses (`abi/kernel.txt`), and erXos's kernel records interrupts in its
  own rings ([design-kernel.md](design-kernel.md#trace-ring)), so the
  patch adds a source, not a format.
* **Coherence.** Each ring has one writer, its CPU, with interrupts off
  in the entry path, and the record is written by the protocol of
  [Sequence-counted records](design-kernel.md#sequence-counted-records).
  The root reads it with the trace ring's own reader
  ([design-fiasco.md](design-fiasco.md#the-trace-ring)), which keeps a
  record only when both loads of its count agree and counts every
  other one as overwritten, so a reader never takes a stamp from one
  entry and a line from another. Nothing new pairs a time with a count.
* **Association.** The two lines the limits time are level-triggered,
  and Fiasco masks such a line at its firing until its holder
  acknowledges it (the paragraph on what a line delivers in
  [design-fiasco.md, Urgency](design-fiasco.md#urgency)), so exactly one entry of the line falls between
  two consecutive receipts of it. Receipt k is paired with the line's
  `irq_entry` records stamped after receipt k - 1 (for the first, after
  the cell's start) and before receipt k. Exactly one makes a sample.
  None, more than one, or any record of that CPU's ring counted as
  overwritten in that window makes the receipt `partial`, never a
  guessed time. A line found edge-triggered, whose entries can merge,
  has every receipt `partial`; that both lines are level-triggered in
  the board's device tree is unverified until the patch lands.
* **Authority and builds.** The rings are kernel-owned, of fixed size,
  and mapped read-only into the root alone. The patch's code and
  mapping sit behind a configuration option that only the development
  Fiasco build sets and that the release configuration's exact
  allowlist ([design-fiasco.md](design-fiasco.md#the-releases-fiasco-build))
  does not admit.

Trace records carry the stamp because the format, the coherence protocol
and the reader already exist and are tested. They keep the accepted
definition, give one timeline from entry to the driver on one clock, and
go with Fiasco when erXos's kernel, whose rings record interrupts,
replaces it.

### The analyser's stimulus

The stimulus's pulses come from a stock Glasgow applet on the board's
Glasgow, which drives them on one pin while capturing two. The stock
applets are checked first; only if none fits does the probe need a small
applet of its own, which is Python, stays out of the tree and needs
approval before its first use.

### The two pins

GPIO 20 is the stimulus and GPIO 21 the response, header pins 38 and 40,
both plain GPIO in the header map and next to each other. Each is held by
one responder alone during a run and recorded with its final
configuration.

### A sustained cell's lines

The root cannot summarize a sustained cell: its spinners are a test
task's, and a test task reaches only the console, through its write,
never the root, while its exit status is one number. So the task writes
the samples and the root, which chose the cell, names it in the `BENCH`
line that follows them. Each window and thread is a small line of its
own, rather than the whole cell in one, so every line is written whole
in one request. The lines take the form of the `BENCH` and `CLOCK`
lines, a word and one JSON object, so the one validator and its fuzz
target read them. `share-tasks` records only task A: task B's spinners
are its load, which keeps one writer per cell and keeps B running
through every window of A's by the order in which the root starts and
stops the two, rather than by two tasks' plans agreeing.

### The first five benchmarks

`vm` is fourth and `lifecycle` follows the five: memory is one of the
three costs these benchmarks exist to show, while `lifecycle`'s
consumers, E-D3 and gate GP, come later in the plan.

### The full matrix

The full forms, three runs of: `park-deadline` at two placements and two
loads, `erlang-timer` at two priorities and two loads, each 60 s;
`sched`'s three sustained cells; and every fast and expensive cell at
100,000 and 1,000 samples, come to an estimated 11 minutes of timed work
a run, about 35 minutes in all under HVF before boots. The milestone
gate does not run the matrix. It runs once by hand, its time is recorded,
and it is proposed for CLAUDE.md's milestone gate list only with that
measured duration.

### Linux's configuration

Every Linux row runs the vendor's stock kernel. A separately identified
real-time kernel is a second row for `wake` only, since the published
Pi 4 latencies are of a real-time kernel.

### How FD32's ten runs combine

[design-fiasco.md](design-fiasco.md#the-releases-fiasco-build) compares
"the patched build's median round trip" with the spread of the unpatched
runs' medians. The patched runs combine as the median of their medians,
each run's reported beside it, as [FD32's decision](#fd32s-decision)
computes it. A different reading changes only that one function.

### The board's way back to its found set

The board comes back by itself: every bench boot ends with the machine's
reset, and the queue's last entry is the pair the board was found with,
so the last bench boot's reset boots it. A power cycle is left to a
person only after a hang below the bench root, a boot that halted the
board, or a board that could not be asked to reboot; in each case the
link names the found target again, so the board comes back on it. The
construction adds nothing to the image but its reset, its deadline and
its boot name, and a power cycle is the board's recovery for every other
hang below the root
([design-fiasco.md, The Raspberry Pi 4](design-fiasco.md#the-raspberry-pi-4)).

### The boot server in the tree

The walk rests on three properties of the boot server: it answers only
`boot.img` and `boot.sig`; it binds a download to one entry at its first
request; and it serves a queue
([design-platforms.md, The HTTP form](design-platforms.md#the-http-form)).
The server on the desk, `pi4_http_serve.rb`, has none of them: it serves
every regular file of its directory, resolves the directory once at its
start, and answers each request from the directory as it is then
(`pi4_http_serve.rb:29`, `:76-84`). It is replaced by one in the tree,
`tools/erx netboot serve` (`NetbootServer`), whose pure decision reads
requests through `Web::Http.read` (`tools/lib/erx/web_http.rb:64`), the
host tool's bounded and fuzzed HTTP reader, and which answers one
connection at a time. The alternative, the script outside the tree
changed to the same contract, would leave the walk's guarantees and the
key's resting on code the tree's tests and reviews do not reach, and the
cost that kept the server out, a second reader of requests with its own
fuzz target, is gone, since `Web::Http` is that reader. That the
bootloader's requests fit `Web::Http`'s subset is unverified; the first
boot through it settles it, and a request outside the subset widens
`Web::Http` rather than adding a reader.

### The network boot the stager drives

The HTTP boot the board's EEPROM uses comes into `Netboot` as its second
form, behind the same `prepare` and `point`, and replaces
`pi4_http_stage.rb`; the EEPROM's configuration does not change. Its
design is [design-platforms.md, The HTTP form](design-platforms.md#the-http-form).
The signing key is given by path (`--key FILE`) to each `prepare`, opened
once without following a symbolic link, and taken only when that
descriptor is a regular file owned by the user running the tool that
grants no permission to group or others. It is read from that
descriptor, held only to sign, and never copied into the tree, `build/`,
a record or a log, nor passed on a command line or in the environment.
Nothing the boot server answers can reach it, wherever it lies: the
server answers two names, `boot.img` and `boot.sig`, of the entry its
cursor names, and no byte of a request becomes part of a path. The key
stays where it is, outside the served tree. The board's check is
unchanged: a bench set is signed and checked as every staged build is,
and a development build runs only trusted code, which a bench image is.

## Open decisions

### A hardware watchdog in the bench root

Arming the board's watchdog in the bench root would reset the board by
itself after a hang below the root too. It costs a reload at the root's
top priority every second through every cell, which the system root
pays as well, and the watchdog's window in a stand-in root that reads no
manifest. **Recommendation: not now.** A hang below the bench root has no
known cause, and the walk already leaves the board to come back on its
found target after a power cycle; the cost is a periodic wake inside
every cell the board measures.

## References

Fetched on 2026-11-23 into `~/erxos-scratch/src-osbench/` and read as
data; nothing fetched was run.

| Source | File | SHA-256 |
| --- | --- | --- |
| L4Re, "Performance Overview", `https://l4re.org/_sources/performance.rst` | `l4re/performance.rst` | `561c3f5cb58e4a3422f4bc96be24b49306b99a5139ce17cb0445e1cdf15d4a1f` |
| seL4 performance page, `https://sel4.systems/performance.html`, generated for sel4bench-manifest `35c22e17` | `sel4/perf2.html` | `0f90d3eb72218f9d802683f2b570a1d518de0614d16768af534ed3f070b89a2f` |
| sel4bench's benchmark sets, `https://docs.sel4.systems/projects/sel4bench/` | `sel4bench/docs.html` | `73d21d088c3022edefccb7f514a53e093e842d55364f81f51f3b85a2a555a144` |
| sel4bench's IPC benchmark, BSD-2-Clause, `apps/ipc/src/main.c` | `sel4bench/ipc_main.c` | `364ab7c13f0e5c625794ad38010dbf66dbaddfe1c609e7847cbb348356545aee` |
| F. P. Schmidt, linux-rt-users, 2022-06-01, cyclictest maxima on the Raspberry Pi 4 | `linuxrt/spinics25944.html` | `5b5a91969f6898e5b486c46d9d838f7973ff148d6e8585224d13a7f77134783c` |
| Trustworthy Systems, comparative L4 IPC performance | `ts/comp.html` | `695e0dcdad8444b9ce6b80169fcae2e0bcb96f10643af320e3ed09928d2c15c4` |

In the tree: [design-fiasco.md](design-fiasco.md) (Urgency, Bands, The
trace ring, Measurements, Verification), [design-build.md](design-build.md)
(What the gates run, Reusing passing boots),
[design-domains.md](design-domains.md#performance),
[design-scheduler.md](design-scheduler.md#performance),
[design-header-io.md](design-header-io.md),
[design-platforms.md](design-platforms.md#netbooting-from-a-mac) (Netbooting
from a Mac), [design-board-sensors.md](design-board-sensors.md), and
[research-baselines.md](research-baselines.md).

Outside the tree, the board's HTTP boot as set up on the development host,
read on 2026-11-24 and not run:

| File | SHA-256 |
| --- | --- |
| `~/erxos-scratch/tools/pi4_http_stage.rb` | `bba85ff71ef683096fb886586050ad67737c884166898edd978eb5626ee6d4ff` |
| `~/erxos-scratch/tools/pi4_http_serve.rb` | `7244ca73bdc5f54935ea0788c2538db7a819083e2454cb8085efed925a3225a1` |
| `~/erxos-scratch/netboot/http/boot.conf`, the EEPROM configuration | `0f25bd6b986f835f120511209bcac1bb9210649f826d7dff8c90dae68222c19f` |
| `~/erxos-scratch/netboot/http/STEPS.txt` | `e2ac61fc908bf2caf1b7e6163a795185cc8e5e64004b9123a3e092fd36ebbc8e` |

That this configuration is the one flashed into the board's EEPROM is
taken from `STEPS.txt` and unverified.
