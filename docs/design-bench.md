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
* **Other systems run on the same board.** Stock L4Re and Linux boot on
  the same Raspberry Pi 4, with the same firmware settings, and run the
  counterpart of each operation: L4Re's own IPC benchmark, and for Linux
  one portable C program, `bench/peer/erx_peer_bench.c`, compiled on the
  board by the system's own compiler. Linux serves as the best-case
  comparison on the board; an operation with no counterpart says so.
* **Two kinds of row, and each says which it is.** The kernel table sets
  the kernels' own paths beside each other: on erXos, Fiasco's IPC and
  the root service as the root task and its test tasks call them, with no
  program and no Erlang on the path. The program table sets beside each
  other what a POSIX program pays for a call, the same C program on every
  system: on erXos through musl, `liberx`'s program layer and the
  services of the program's session, mostly Erlang
  ([What a program sees](#what-a-program-sees-posix-and-erl)). The
  Erlang table sets the runtimes beside each other.
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
the 99th percentile of a Pi 4 wake; erXos measures those on
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
same file). Fiasco runs its timer one-shot in erXos's configuration: each
timeout and slice end programs the timer, never sooner than 200 us after
the CPU last handled its timeout queue
([design-fiasco.md, Scheduling](design-fiasco.md#scheduling), "The
quantum"), and the `wake` benchmark shows what a timed park pays for it.

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
their sequence numbers, the counts of lost, early and missed events, and,
for a batched cell that keeps it, its `total` ([the one clock](#the-one-clock)).
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
| `monotonic` | a POSIX guest's `CLOCK_MONOTONIC`, read by `erx_peer_bench` where user mode cannot read the counter, and the operating system's clock stock ERTS's monotonic time derives from (which clock ERTS takes on Linux is unverified); its ticks are nanoseconds | intervals inside another system's guest |
| `cycles` | the CPU's cycle counter, read by another system's own program (ipcbench reads the architecture's cycle counter register directly) | that program's totals, which it prints in cycles |

A guest's samples are in ticks; nanoseconds are derived when the record is
read, from the frequency the run recorded. Cycles as a unit are a counter
interval times the CPU frequency that the same run measured, and are
`unknown` where the run could not measure it. The `cycles` clock is
different: no run that reads it measures the CPU's frequency, so it has
none, and its intervals are never turned into nanoseconds, by its own
run or by another's calibration.

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
* the CPU's cycle counter's advance per counter tick over one second,
  which a disposable test task measures where its cycle counter is
  readable in user mode ([The cycle counter](#the-cycle-counter)), and
  otherwise `unknown`; the `CLOCK` line carries it as a number or
  `unknown`. On the Raspberry Pi 4 it is the CPU's cycles per tick; under
  HVF it is what the virtual machine's cycle counter makes of a tick,
  which is not the host core's cycles.

The rule applies to a cell whose start and end stamps are read on
different CPUs; a round trip stamped on one CPU needs no calibration,
wherever its work ran. Such a one-way interval is corrected by the
interval's middle and reported with its half-width as its uncertainty,
and its cell reports `unsupported` with the reason of the `CLOCK`
paragraph in [A benchmark](#a-benchmark) when an interval is null, the
two do not overlap, or the half-width is more than a tenth of its
median.
A round trip is never halved into a one-way number.

**Short operations.** An operation whose warm-up median is under 100 of
the clock's smallest increments, as the boot's calibration observed
them, is timed in batches: the smallest power of two of operations that
spans 100 increments, at most 256. On the counter an increment is one
tick; on a clock in nanoseconds that steps more coarsely, as ERTS's
time on erXos does and a C library's `CLOCK_MONOTONIC` may, it is that
step, so a coarse clock batches as far as a fine one in its own steps.
An operation that a batch of 256 does not lift over 100 increments keeps
that batch: its percentiles are of few steps, which its batch size and
its boot's `CLOCK` line show, and the mean of its `total` is the number
to read. The C and Erlang guest libraries apply this one rule. The record states the batch size, and its percentiles
are of batch means; they are never called per-operation tails. Each
sample is its batch's ticks over the batch, rounded down, so an operation
of a few ticks reads in whole ticks. A cell may therefore also report
`total`, the ticks its timed batches spanned, added up before any is
divided: the host derives the cell's operation count, its samples times
its batch, and its mean, the total over that count, and refuses a total
that its samples rule out: below the batch times the least sum their
histogram allows, or above the batch times the greatest sum plus the
batch less one for each sample. Only a `fast` cell reports it, and never
one with an uncertainty, whose samples are corrected and its total would
not be. `nullcall`'s cells report it,
so the side-by-side table sets their mean beside a counterpart's `mean`:
both are an operation's share of a run timed whole, while the median is
of rounded batch means. An
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
A form's run is one boot of each image the benchmark needs, so a form
of three runs boots each image three times: three records of one boot
each in QEMU, one record of three boots on a board's walk
([The record](#the-record)), and three boots of a comparison either way.
The sizes are starting values, to be revised by the first calibration
runs.

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
* **The phase sweep.** A timer whose interrupts keep a rhythm of their
  own, a periodic tick or a housekeeping interrupt counted from the last
  one, makes
  a deadline's lateness depend on where the deadline falls in that
  rhythm, and deadlines a whole period apart would all fall at one phase,
  set by when the run happened to start. Deadline k is therefore the first
  deadline, plus k periods, plus `(7k mod 16) / 16` of a period, which
  visits sixteen phases in turn. Within a run, lateness is reported per
  sweep phase as the minimum observed lateness and the excess above that
  minimum. The minimum holds the timer's rounding together with whatever
  delivery and scheduling cost every period paid, so it is not called
  rounding, and the excess is not called scheduling delay; telling them
  apart needs a stamp of the timer's own firing, which no cell has. A
  sweep phase is counted from the run's first deadline, not from any
  timer event, so phases are not matched across runs: comparisons use the
  distribution over all phases. On Fiasco a deadline that falls within
  200 us of the CPU's last handling of its timeout queue waits for that
  floor ([design-fiasco.md, Scheduling](design-fiasco.md#scheduling),
  "The quantum"); a minimum that varies across the phases by up to
  200 us is the sign of it.

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
| QEMU `virt` under HVF | `qemu-hvf-<model>-<n>cpu-<system>`, `<model>` the host's hardware model | the development numbers and the landing gate | itself; side by side with `host`, and with the other systems in the same kind, model and CPU count |
| QEMU `virt` under TCG | `qemu-tcg-<model>-<n>cpu-<system>` | functional runs on hosts without HVF | itself only |
| deterministic mode | `qemu-det-<system>` | deterministic virtual time of one CPU, the same at every run of the same inputs | itself only |
| the Raspberry Pi 4 | `pi4-4gb-<system>` | the native numbers and the three limits | itself; side by side with the other systems on the board |
| the host | `host-<model>` | stock OTP natively | side by side with `qemu-hvf` |

Every environment that boots a guest names the system the guest runs,
one of `erxos`, `l4re`, `linux`, and `genode-hw`,
`genode-sel4` and `genode-foc`, Genode on each of its kernels
([Genode's guest](#genodes-guest)). The system is part of where
a run happened, not of what ran, so two systems' records never have equal
environments, and no comparison can give one system's number as a
verdict on another's: setting systems beside each other is only ever the
side-by-side table.

QEMU's `raspi4b` model is not an environment: it runs only under TCG, and
its numbers describe the model. Under HVF, a guest's CPU affinity does not
pin the host thread that runs it, and macOS has no way to; the record
keeps the host's load average before and after.

### The record

One run is the record of one subject's boots in one environment by one
invocation of `tools/erx bench`: a QEMU boot's run holds its one boot,
and a board's walk writes one run for each set it boots, holding that
set's boots, one per queued entry
([The record of a board run](#the-record-of-a-board-run)). Each boot
has a **position**: its entry's position in the walk's queue, or 1 for
a QEMU run's one boot. A boot is the unit the comparison
counts ([Comparison](#comparison)). The run's directory is
`<history>/bench/<environment>/<run>/`, where `<history>` is
`ERX_BENCH_HISTORY` or `~/erxos-history`, and `<run>` is the UTC time,
the source revision's first twelve hex digits, `-dirty` when the tree
was, and the first twelve hex digits of the SHA-256 of the subject's
fields as JSON, so that two sets of one revision that one walk
boots are two runs:

```
run.json                            the manifest
boot-<n>/<benchmark>/<operation>.json
                                    every cell of the operation in the boot at
                                    position n, each keyed by its conditions,
                                    with its histogram, largest samples and
                                    raw samples if few
boot-<n>.serial.log                 that boot's console
boot-<n>.qemu.log                   that boot's QEMU output
compare.json                        a comparison made against this run, if any
```

`run.json` holds, as CLAUDE.md requires and the comparison needs:

| Group | Fields |
| --- | --- |
| environment | kind, machine model, CPU count, memory, operating system and its version, accelerator, QEMU version and machine type, firmware files' SHA-256 on a board |
| subject | source revision and whether the tree was dirty, image SHA-256, every workload source's SHA-256, compiler version, the complete compile and link flags, the system manifest, runtime flavour and scheduler flags, the Fiasco configuration |
| run | date, the tool's revision, what started it (`landing`, `milestone`, `gate G5`, `manual`), the host's load before and after, `reused_from` for a reused boot, and the run's other facts, such as a board walk's sensor readings and how the walk ended |
| boots | per boot, in ascending positions: its position; its own facts, such as a board entry's name, its `boot.img` SHA-256 and the walk's outcome for it; its clock, the calibration above; and its cells: benchmark, operation, the cell's conditions (load cell, placement, workload parameters, clock, batch size), profile and its sizes, status and reason, sample count, the summary the profile allows, lost, early and missed counts, and its operation file. A boot holds each cell once; every boot of a run holds its own |
| baseline | for a run that was compared: the baseline runs' paths |

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

**A mean.** A cell's summary takes one of two forms. Every cell erXos's
guests, `erx_peer_bench` and the Erlang bench modules report is a
`histogram`, summarized as above. A cell read from another system's own
program, which prints only a total and its mean, is a `mean`: the
operation count, the interval over all of them and the mean the program
printed, in that program's clock, and nothing else. Its samples,
percentiles, maximum, minimum, and lost, early and missed counts are
absent, never zero, and its boot has no `clock` group, since that program
measures no calibration; the rule that a boot needs one `CLOCK` line binds
boots that print `BENCH` lines. A `mean` is `measured` when its program
reported the cell and printed no error for it. It is shown in the
side-by-side table and never compared.

A file is at most 1 MiB and a log at most 64 MiB, each bound applying
to every boot's files apart, and a run directory is
created exclusively, never over another. Every file name is derived from
the validated declarations (benchmark and operation names) and the
boot's position, never from a guest's line, and the reader derives each
operation file the same way and refuses a manifest that names another.
Records are never edited; a
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
cell's longest gap) of one cell between a **baseline**, at least three
boots, and a **candidate**, one boot or three. Each boot of a record is
one side, whatever its cell's status, so one run of three boots is as
many as three runs of one, and a boot that booted twice (its cells
`rejected`) or never began (`not_run`) stays a side and makes the
comparison inconclusive rather than shorter. A boot without the cell
ran other cells, and is refused.

* **Comparable.** The two sides must have equal environments and equal
  cells: the same operation, load cell, placement, workload parameters,
  clock, batch size and profile sizes. Anything else is refused with what
  differs. A `mean` cell is refused whatever it is compared with: one
  number per run has no distribution to compare. The one exception is the
  side-by-side table, which sets `qemu-hvf` beside `host` for G3, and
  beside each other the systems of environments that differ only in their
  system, and gives no verdict. Everything that depends on the system
  (its kernel, its command line, its configuration, its pins) is in the
  run's `subject`, so the environment fields of one host, accelerator,
  QEMU, machine type, CPU count and memory are the ones that must be
  equal, and the subjects are shown beside the numbers, not matched.
* **The noise band.** The band of a statistic is the range of its values
  across the baseline's boots, widened by one histogram bucket.
* **The verdict.** `same` when every candidate boot lies within the band;
  `slower` when at least two of three candidate boots lie above it and the
  candidates' median exceeds the baseline's by more than the advisory
  threshold; `faster` the mirror; `inconclusive` otherwise. A sustained
  cell is judged on its longest gap over all windows, an exact number
  whose band is not widened, against the 99th percentile's threshold,
  since it is the cell's tail. Deterministic mode's band has no width,
  so any difference there is a real change of the measured virtual time,
  though not necessarily of instructions executed.
* **Inconclusive is not a pass.** A comparison is inconclusive when the
  baseline has fewer than three boots, when any side's cell is not
  `measured`, when either host's load average exceeded half its CPUs (a
  starting value, revised with the thresholds), or when the verdict above
  is mixed. A change that CLAUDE.md requires numbers for has not
  supplied them while its comparison is inconclusive, whatever the suite
  that ran it reported.
* **A replayed boot is not a new run.** A log the gate's store replays
  ([The gates](#the-gates)) is evidence of the run that recorded it. It
  never counts as a calibration run, an independent baseline boot or a
  side of a paired run.
* **Maxima and misses stand apart.** A maximum, a missed period or a lost
  wake is reported in every comparison even when every percentile is
  `same`.

**Paired runs.** On a shared host, a baseline recorded last week and a
candidate run today differ by everything else the host did. Only a paired
comparison can say `slower` or `faster`: `tools/erx bench NAME --paired
--image-a BASE --image-b CAND` boots the two images alternately, three
times each (A B A B A B), on one host in one session, each boot a record
of its own, and compares them by
the rule above. The developer builds the two images; the tool builds
nothing. A comparison with a recorded baseline and one candidate boot, as
the landing gate makes, can say only `same` or `outside the band`, the
second meaning that a paired run is needed.

**Advisory thresholds.** The thresholds below are starting values. After
the first three boots of an unchanged subject in an environment, each
becomes the larger of its starting value and the spread those boots
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

Exactly three limits fail a gate, each becoming hard once three boots of it
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

**The landing matrix.** Four boots, each running its cells one after
another and never two at once, so that sharing a boot changes no cell's
background:

| Boot | Cells |
| --- | --- |
| the native bench image, QEMU `virt` under HVF, four CPUs | `nullcall`: `root-same-space` and `root-cross-space` on the service's CPU, and `kernel`; `vm`: `reserve`, `commit`, `touch`, `protect`, `decommit` and `release` of one page, from a test task; `wake`: `wake-same-cpu`, `wake-cross-cpu` and `trigger-take` on one CPU, and `park-deadline` on one CPU, idle, for 2 s; `sched`: `share-equal` with four spinners on the last CPU, three 1 s windows |
| the same image in deterministic mode | `nullcall`'s two root cells and `vm`'s one-page `commit` and `protect`, 1,000 samples each |
| the `xdomain` bench image, under HVF | `xdomain`: `local-rtt` and `xdomain-pingpong`; `wake`: `erlang-timer` at `normal`, idle, for 2 s |
| [Linux's Erlang guest](#linuxs-erlang-guest), under HVF, one CPU, then the same boot of its seeded `/init` | `xdomain`: `local-rtt` and `xdomain-pingpong` on stock OTP, recorded as Linux's; the seeded boot's `xdomain-pingpong` must be `failed` beside a `measured` `local-rtt` (the test row below). Its suite cell, `hvf-1cpu-linux-erlang-xdomain`, is `not_run`, the reason in the suite's notes, when the oracle's install export or Linux's fetched pins are missing |

Every fast cell takes the landing form's 10,000 samples. The timed work
is about 10 s; the rest of the suite's time is the boots and their
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
the committed runs of the same environment whose source revision is an
ancestor of the candidate's, with no dirty tree, that hold the cell,
taken newest first until they hold three boots (`BenchCompare.baseline`):
one landing run
is one boot, so its newest run alone would always leave the baseline
short. A comparison that is `inconclusive`, `no baseline` included, does
not fail the suite, and does not supply the numbers either: the change
then needs a paired run.

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

* **A bench image builds for the board.** `NativeBench::Run` builds
  Fiasco for its platform when asked to rebuild (`fiasco.build_for`,
  `tools/lib/erx/native_bench.rb:257`) and keeps a board's builds apart
  from QEMU virt's (`board_part`, `:288`); `BootImage` packs the
  platform's own first stage (`first_stage`,
  `tools/lib/erx/boot_image.rb:76`) and checks the single file against
  that first stage's load address (`:58`). `NativeBench::BoardSets`
  builds each distinct benchmark's image for the board and lays it out as
  a boot partition's files and build record in `build/bench-board/`
  (`native_bench.rb:321`). `Run#boot` boots only QEMU (`:290`); the
  board's boots are the walk's.
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
* **The cycle probe is untried on the board.** The root runs it on every
  boot (`bench_cycles_probe`, `test/guest/native_bench/cycles.c`). The Fiasco
  build sets `CONFIG_PERF_CNT_USER` (`config/fiasco/kernel.defconfig:17`),
  under which Fiasco turns the cycle counter on and opens the performance
  monitor to user mode on every CPU it starts (`Perf_cnt::init_cpu`,
  `fiasco/kernel/src/kern/arm/perf_cnt-arm.cpp:211-228`); whether the
  firmware's levels above the kernel leave that read untrapped on the
  board is unverified.
* **The host reads the board's console, live or afterwards.** The walk
  reads it through `BoardConsole` while it runs, which classifies each
  line it holds whole with `BoardLog.classify`
  (`tools/lib/erx/board_console.rb:113`); `tools/erx bench import` reads a
  saved log of it afterwards (`bench_import`, `tools/erx:1591`); and both
  runs' records come from one reader of board logs (`BoardLog.read`,
  `tools/lib/erx/board_log.rb:78`), which `BoardRecord.recorded` calls.
  `BoardConsole` opens a serial device or a console served as a TCP
  port ([Raspberry Pi 4 guide](guide/raspberry-pi-4.md)).

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
  Every bench image, a board set's as QEMU's, packs `native_task`'s
  program, which the cycle probe runs
  ([The cycle counter](#the-cycle-counter)).
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

The run tests the read rather than assume it. On every boot, before its
cells, the root launches `native_task`'s program as a disposable test task
in a mode of its own, `MODE_CYCLES`, on the root's CPU: the task reads the
cycle counter and the system counter, spins one second by the system
counter, reads both again, and exits with the cycles per tick in
thousandths, as `MODE_TURNS` exits with its median. The read is one
accessor beside `erx_fiasco_counter` in the backend's architecture layer,
`erx_fiasco_cycles` (`liberx/backend/fiasco/arch/aarch64/clock.c`), over
the generated read of the cycle counter register from
`hw/sysreg/aarch64.json`, which
the `sysreg-read` chokepoint permits in that file alone. The task's
records come to a gate of the root's, as `vm`'s disposable task's do, so
a fault on the read is an answer, not a lost boot.

| What the task does | What the `CLOCK` line carries |
| --- | --- |
| exits with a positive count | the count, as `cycles_per_tick` |
| faults on the read, which ends it with a fault record as `vm`'s disposable task's write does | `unknown`; the root prints `erx: bench: cycle counter: not readable in user mode` |
| exits with 0: the counter did not advance | `unknown`; the root prints `erx: bench: cycle counter: did not advance` |

The root's line is for a person reading the log; the host reads only the
`CLOCK` line. QEMU's boots run the probe too, since ipcbench's totals
under HVF are read from the same register and only the probe says what
that register counts there. A cycle counter under an emulator or a
hypervisor counts what QEMU or the host makes of it, not the host CPU's
cycles, so a QEMU boot's count is a fact about that virtual machine.
The probe adds about a second to every boot, inside the guest's
deadline. The count never converts an interval: an erXos cell stays in its
counter's ticks and a `cycles` cell in cycles; a reader puts the two on
one clock by the boot's count, by hand, and says so.

What the probe found under HVF (QEMU 11.1.3, `-accel hvf -cpu host`, the
primary host, an Apple M3 Max, model `Mac15,9`, as the records name it;
one boot of each native benchmark of `--suite bench` and the two erXos
boots of one `nullcall` session against L4Re, on 2026-11-24 and 25, HVF
only): the cycle counter is readable in user mode
under erXos's Fiasco and advances, at 128.000 counts per tick of the
24 MHz counter, 3.072 GHz, in nine of those ten boots and 128.001 in
one. A ratio exact to a thousandth over one second is not a
core's clock, whose frequency moves
with its load and its performance state: under HVF the guest's cycle
counter is the system counter scaled by 128, so it resolves no more than
the counter does, unless its step is finer than 128: every ipcbench
total read is a multiple of 64, the session's three (1,052,416,
2,922,112 and 5,755,008) of 128, and no pair of reads has measured the
step.
Under HVF a `cycles` total is therefore a time, 1/3.072 ns per count, and
erXos's ticks times 128 are counts of the same clock. TCG was not run.

### The walk

`tools/erx bench NAME --env pi4-4gb-erxos --console DEVICE|tcp:HOST:PORT --ssh DEST
--key FILE [--http DIR] [--runs N] [--profile landing|full] [--set DIR ...]` runs it,
with `--http DIR` the served link that `tools/erx netboot --http` stages and
`tools/erx netboot serve --http` serves (`~/erxos-http` when not given):

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
2. It opens the console, a serial device set to 115,200 baud or a TCP
   port that serves it, such as a Glasgow UART applet's, which it reads
   directly, and starts the log. Over
   ssh it reads `/proc/sensors/status`
   ([design-board-sensors.md](design-board-sensors.md#procsensors-and-the-inspector)):
   the SoC temperature, the throttle state and the ARM clock before the
   run, `unknown` where the path is unsupported.
3. It points the link at the queue (`Netboot.point`) and asks the running
   system to reboot: `ssh -o BatchMode=yes -T -- DEST reboot`, which
   root's session may run, since it holds the `machine` grant
   (`config/manifest/development.txt`, `facet machine`). The destination
   is checked as `CodeSsh` checks it, and batch mode makes a password or
   host-key prompt fail at once. If ssh fails, the run types `reboot`
   and a carriage return on the console it holds, as root's console
   session takes it, says so, and asks for a reset by hand if the board
   does not restart within the boot deadline, which runs from the request.
   A console that cannot be written is closed, and the walk ends with its
   console closed.
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
   (`BenchRecord::LOG_BYTES`), not only when the
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
`BoardConsole` opens the device read-write and sets its line, or connects
to the console's TCP port, types on it only the walk's reboot request, and
appends what it reads
to the log, yielding each line, at most a `BENCH` line's 64 KiB and its
end, to the walk. `BoardRun` is the walk's effects around them: under
the lock it reads the found target and its return identity, prepares
the queue, writes `queue.json`, reads the sensors, points the link at
the queue and asks the board to reboot over ssh, hands the console's
lines to `BoardWalk`, points the link back, writes `walk.json`, reads
the sensors again and hands what it has to the record. Nothing else is
new: the image is `BootImage`'s, the
set `BootPartition`'s, the judge `BenchMeasurement`'s and the writer
`BenchRecord`'s. Every byte of the board's that the run shows, in its
own diagnostics or from ssh, reaches the terminal only through
`LineEscape`, and nothing the board prints names a path, a command or a
signing input: a boot name only selects an entry the host prepared.

### The record of a board run

The record is the one of [The record](#the-record), in
`bench/pi4-4gb-erxos/<run>/`, one per subject: a walk writes one for
each distinct set it boots, holding that set's boots, one per queued
entry of the set, at the entry's position in the queue, and a paired
walk writes a comparison beside them. Each boot is one side of the
comparison, so a walk of three entries of one set is a whole
baseline, and an entry that never began or booted twice stays a boot
of its record and makes the comparison inconclusive:

* **environment**: kind `pi4`, system `erxos`, four CPUs and 4,096 MiB,
  and the SHA-256 of every firmware file from the build record of the
  set the record is of;
* **subject**: the source revision, the SHA-256 of the set's
  `kernel8.img` and of its build record, the root's flags as the queue
  names them (absent for a set handed to the walk with `--set`, whose
  flags the walk does not know) and the compiler the set's build record
  names;
* **run**: the date the queue was made; the sensor readings before the
  run and after the return, each named for when it was read and kept
  line by line through `LineEscape` (unknown in an import, which has
  none); how the walk ended; and two facts kept
  apart: `restored`, whether the link named the found target again at
  the run's end (on the host), and `returned`, what the board booted
  after the last entry (`booted`, `unexpected` with the banner's build
  and index hash, `unknown` or `not_seen`);
* **boots**: each of the set's entries, at its position in the queue,
  with its name and `boot.img` SHA-256, the walk's outcome for it and
  how it ended, its clock and its cells, which `BoardLog` judges from
  its lines ([Importing a log](#importing-a-log)): an entry that never
  began has its cells `not_run`, and one that booted twice has them
  `rejected`. Its `boot-<n>.serial.log` is the console from the end of
  the entry before it in the queue, or the run's start, to the end of
  the entry's own last line and the `erx: end` line after it, so the
  bootloader's and the firmware's lines stay in the log of the boot
  that follows them; the bytes after the last entry, the return among
  them, end the last entry's log.

### Importing a log

`tools/erx bench import NAME --env pi4-4gb-erxos --queue FILE [--profile
P] LOG` makes the record of a walk from its log, when the walk's own
record was not written (a history root refused, a host that died). The
queue's file, `queue.json`, which the walk writes beside its log under
`build/bench-board/` before it serves the queue, names when it was made,
each entry's name, its position, its `boot.img` SHA-256 and the set it
was made from (the set's directory, its build record's SHA-256 and its
root's flags, which the build record does not hold), and the found
pair's return identity; the walk's outcomes, `walk.json`, are written
beside it as the walk ends: each entry's outcome (`ended`,
`ended_unseen`, `stopped` by the walk's ending, or `not_run`), how the
walk ended, `restored` and `returned` (`BoardFiles`); without it, how
the walk ended, `restored` and each entry's outcome are recorded as
unknown. A log of boots that print no names has nothing that ties a
line to a boot, and is refused. A set's build record that is no longer
the one the queue names is refused, so a record never pairs a walk's
boots with another build's facts.

The reader is `BoardLog`, a pure function of the log's bytes, the queue,
the sets' asked cells and the walk's outcomes when it has them. It
places each line by the rule of
[the construction](#the-construction-the-server-hands-out-a-queue): a
line naming an entry, and every line between two consecutive edges
that both name that entry, belong to that entry's boot, where an edge
is a naming line, a banner or an `erx: end` line; any other line
belongs to none. A banner or an end line starts or ends a boot, so no
bracket spans two boots, and a naming line that names no entry, or is
broken, brackets nothing. A
name is exactly thirty-two lowercase hexadecimal digits and a banner's
build and index hash exactly 16 and 64, the handoff's sizes. Each
entry's `BENCH`, `CLOCK` and `WINDOW` lines go to `BenchMeasurement.boot`
against what `NAME` asks at profile `P`, as a QEMU boot's lines do: as
timed out when the entry printed its `deadline` line or the walk's end
deadline passed in it. An entry that printed neither `done` nor
`deadline` has its unreported cells `not_run` with the walk's reason
when the walk gave one (an interruption, a closed console), and
otherwise with `the log ends before its boot did` or `the end of its
boot was not seen` (a later naming line, machine end or banner shows
it ended), never `timed_out`, which only a deadline someone saw says;
an entry no line names has them `not_run`, `no line of the log names
its boot`.
An entry whose naming lines lie on both sides of another entry's
naming line or of a banner booted twice, and all its cells are
`rejected`; a boot's slice of the log that is over a boot's bound is
refused: 64 MiB, or less in a walk so long that its whole log would
pass 512 MiB, so any walk's log is read at once, and the walk holds each
boot to the same bound. The live run's record is the
same function of the log it captured. Every byte the reader takes is
the board's, untrusted: nothing it reads reaches the terminal but
through `LineEscape`, and the reader is fuzzed with the bench lines'
reader.
## Other systems in QEMU under HVF

erXos is set beside L4Re, Linux and Genode first in QEMU's `virt`
machine under HVF on the development host, where it is measured every
day, and on the board after.

**What a row compares.** The kernel table's rows are kernel against
kernel: erXos's cells there are the root task's and its test tasks'
calls of `liberx`, a request to the root service or a call of Fiasco,
beside a Linux system call or an L4Re IPC, and no program on erXos makes
them as such. The program table's rows are what a program sees: one C
program's POSIX calls, on erXos through musl and `liberx` to the
service that owns each call, mostly Erlang in the program's session,
and on Linux and Genode through their own C libraries
([What a program sees](#what-a-program-sees-posix-and-erl)). The Erlang
table's rows are ERTS against stock OTP. A reader asking what Doom pays
for a `read` on erXos reads the program table; one asking what erXos's
kernel and root service add to every request reads the kernel table.

**The construction.** A comparison is one environment with only its
system varied. Each system's guest boots through the one QEMU plan the
erXos cells use (`QemuPlan.argv`, `tools/lib/erx/qemu.rb`): the same
pinned QEMU, the `qemu-virt` platform's machine line, `-accel hvf -cpu host`,
the CPU count and memory of the erXos boot it is set beside (four CPUs
and 512 MiB for the native bench image, `NativeBench::MEMORY_MIB`), no
network device, no disk, `-no-reboot`, a deadline and its serial log.
Only what follows `-kernel` differs: erXos's bench image, Linux's kernel
with an initramfs, L4Re's `bootstrap.elf`. Each guest reports on its
console; the BENCH and CLOCK lines go through `BenchMeasurement` as
erXos's do, and L4Re's own lines through its importer. Each boot is one
run in its own environment, `qemu-hvf-<model>-<n>cpu-<system>`, written
by `BenchRecord.write`, so the record format is the one this document
defines and the side-by-side table is the one view across them. The
board form is the same session with the board's boot step per system
in place of QEMU's.

### A comparison session

`tools/erx bench NAME --systems erxos,l4re,linux,genode-hw` boots, on one host in
one session, each listed system's guest for the cells of NAME that system
has a counterpart for, one system after another and never two at once,
in rounds: one round in the landing form, three in the full form
(`--profile full`), the order given in the first round and turned by one
system in each round after it, so in the full form each of three systems
boots once in each position. Neither rounds nor the turning remove the
host's drift: they keep it from following one system's position, and the
record shows it, as the rounds' spread and the host's load before and
after each boot. A session gives no verdict, so it needs no pairing rule
beyond that. Each system boots in two forms of the environment, one
CPU and four: same-CPU cells are read from the one-CPU form, where every
thread of every system shares the one CPU, and cross-CPU cells from the
four-CPU form; L4Re boots in the one-CPU form only
([L4Re's guest](#l4res-guest)). The session writes each boot's run as the
boot ends, so a system that fails leaves its record and the session goes
on with the next, and then prints the side-by-side tables of its runs. It
runs by hand and at the plan gates that ask for it, never at the landing
gate, which keeps its one system.

The side-by-side table is three tables, the kernel table and the Erlang
table of [Counterparts](#other-systems-on-the-same-raspberry-pi-4) and
the program table of
[What a program sees](#what-a-program-sees-posix-and-erl), each with a
row per erXos cell and a column per system: each run's status, its
clock, its summary's form, the median, 99th percentile and maximum of a
`histogram` where its profile allows them, with its operation count and
mean where it reports its total, or the operation count and mean of a
`mean`, and the counterpart's line. It prints nanoseconds for
the clocks that have a frequency (`counter`, `monotonic`) and cycles for
`cycles`, and sets a ratio only between two cells of clocks with a
frequency. A cell in `cycles` gets no ratio and no conversion, whatever
another boot's `CLOCK` line measured: a calibration describes only its
own boot, and under HVF the next boot may run on other host cores.

The record of a run that is not erXos keeps, in its `subject`, the erXos
source revision of the harness and of `erx_peer_bench`, and every pin
the guest was built from:

| System | `subject` details beyond erXos's |
| --- | --- |
| `linux` | the kernel's pin (`deps.lock` id, version, SHA-256) and its command line, the initramfs's SHA-256, `erx_peer_bench`'s SHA-256, the compiler's version and complete flags, the C library's pin; for an Erlang boot, also the exported OTP tree's SHA-256, the OTP version and flavour the guest reported, the toolchain image's digest, and each packed library's SHA-256 |
| `genode-hw`, `genode-sel4`, `genode-foc` | Genode's release and its SHA-256, the tool chain's version and SHA-256, the kernel and board the build named, the resolved run configuration's SHA-256, the boot image's SHA-256 |
| `l4re` | each L4Re repository's pinned commit, the resolved Fiasco configuration's SHA-256 and its difference from erXos's, the compiler's version and flags, the toolchain image's digest, `bootstrap.elf`'s SHA-256 |

Each boot's serial log is kept in its run directory as every boot's is;
Linux's holds the kernel's own report of its version, CPU features and
mitigations, which the record therefore keeps without parsing.

### Cells under HVF

What each system runs is [the counterparts table](#other-systems-on-the-same-raspberry-pi-4).
Under HVF:

| erXos cells | Set beside | What HVF adds |
| --- | --- | --- |
| `nullcall.kernel` | L4Re, Linux | a system call is expected not to leave the guest, unless the guest's path touches a register HVF traps (unverified for all three) |
| `nullcall.root-same-space` | L4Re, Linux | the same |
| `nullcall.root-cross-space` | L4Re, Linux | the same; an address-space switch is expected to stay in the guest, under the host's stage-2 translation |
| `wake.wake-same-cpu`, `wake.wake-cross-cpu` | Linux | an idle vCPU's `WFI` exits to the host, so a wake to a sleeping CPU includes macOS waking QEMU's thread |
| `wake.park-deadline` | Linux | the timer interrupt is delivered through QEMU's interrupt controller, so lateness includes the host's delivery |
| `vm.commit`, `vm.touch`, `vm.commit-touch`, `vm.protect`, `vm.decommit`, `vm.map` | Linux | the first touch of a guest-physical page faults to the host as well (below) |
| `sched.share-equal` | Linux | each vCPU is a host thread macOS schedules |
| `xdomain.local-rtt`, `xdomain.xdomain-pingpong` | Linux, stock OTP | the wake costs above |

erXos's alone: `wake.trigger-take`, `wake.erlang-timer`,
`sched.share-tasks`, `sched.band-work`, `vm.reserve`, `vm.release` and
`vm.mem-child`. `wake.gpio-edge` and the three limits are the board's
alone; QEMU's `virt` has no pins to time. The program table's rows,
under HVF as on the board, are those of
[What a program sees](#what-a-program-sees-posix-and-erl); what HVF adds
to them is what it adds to the kernel rows beneath them.

### Linux's guest

**Kernel.** Alpine Linux 3.24.4's `virt` kernel, `vmlinuz-virt` from the
release's netboot directory
(`https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/netboot-3.24.4/`),
pinned with its configuration file beside it in Linux's own lock,
`bench/linux/deps.lock`, in `deps.lock`'s form, and read as data. Only
`tools/erx fetch --linux` reads that lock, as only `--l4re` reads
L4Re's: a default fetch does not download Linux, and a `--cache` fetch
does not need it. It publishes each pin under `build/linux-sources`, a
root of its own (`tools/lib/erx/side_lock.rb`, which both locks share),
so no id it names can replace a source of erXos's lock. It is the distribution's
stock kernel for virtual machines, built by the distribution, unmodified,
and booted with its own defaults: no option that changes mitigations or
preemption. Alpine was chosen because its releases are files at
versioned URLs with published SHA-256 sums, need no account, and boot
offline without a disk image. Its configuration
(`config-6.18.60-0-virt`) shows what the comparison depends on: Linux
6.18.60, the PL011 console built in, `HZ=1000`, `NO_HZ_FULL`,
`PREEMPT_NONE` by default with `PREEMPT_DYNAMIC`, 4 KiB pages, an
initramfs with gzip support, PSCI, and `EFI_ZBOOT`. The kernel file is
an EFI zboot image: its first bytes are `MZ`, `zimg` and the compression
name `gzip`. QEMU's `-kernel` loads such an image as it is, so the boot
step inflates nothing.

**User mode.** No distribution user mode at all: the initramfs holds
`/init`, a small C17 program of the tree (`bench/linux/init.c`),
`erx_peer_bench` beside it, the directories `/dev` and `/dev/shm` with
`/dev/console` as a character device, and `/proc`, the directory `/init`
mounts `/proc` on. A Ruby writer of the `newc` format
(`tools/lib/erx/newc_archive.rb`) makes it, so the host needs no `mknod`
and no `cpio`. The kernel runs `/init` as process 1. It mounts `/proc`,
which the `wake` handshake reads, starts `erx_peer_bench` with the
arguments the kernel gave it, and waits for the program under the
guest's deadline, which the build passes it from
`LinuxGuest::DEADLINE_SECONDS`: ten seconds after the program's own
`SIGALRM` deadline, which `PeerBench` passes the program, so the kill
is only a backstop. QEMU's deadline for the program's `done` line is
that and the margin an erXos boot's has, so `/init` ends a hung boot
first; the boot then has no `done` line and fails, with what `/init`
printed in its serial log, and records nothing (erXos's guest instead
marks the cells it did not report `timed_out`). However the program ends, by its exit, a signal or
that kill, `/init` prints how unless it exited with 0, drains the
console and powers the machine off with `reboot(2)`, and QEMU exits;
should the power-off fail, `/init` returns and `panic=-1` ends the boot.
It waits in `sigtimedwait` on `SIGCHLD` with the time left as its
timeout, so it wakes only when a child ends, and nothing else
runs in user mode, as nothing else runs beside erXos's bench root and
its test tasks. The initramfs's root file system is in memory, so
`shm_open` under `/dev/shm` needs no mount (unverified).
`erx_peer_bench` is the same program on every system but for its CPU
pinning and its `wake` handshake's reading of `/proc`.

**Build.** `erx_peer_bench` and `/init` are compiled on the host by erXos's own clang
(`ERX_CLANG`) and linked by `ld.lld` for `aarch64-linux-musl`, static,
against the headers, start files and `libc.a` of Alpine 3.24.4's
`musl-dev` package, pinned in Linux's lock as a `tar` source whose
members are those five paths under `usr`, so the fetch step's one
unpacker verifies, bounds and extracts only them. The link needs
compiler helpers: musl's `long double` `printf` reaches the binary128
arithmetic, which erXos's compiler-rt builtins archive supplies. The profile sizes reach it
as they reach the erXos guest it is set beside, so a cell's profile is
equal on both sides. One static binary runs on any AArch64 Linux, so the
board's Linux row can carry the same file ([open decision](#open-decisions-of-the-comparison)).
Nothing of Alpine runs on the host: `musl-dev`'s headers, start files and `libc.a` are
input files to erXos's clang and `ld.lld`, and the kernel runs only
inside QEMU, whose guest has no network device.

**Boot.** `QemuPlan.argv` with `-kernel` the kernel, `-initrd` the
initramfs, and `-append "console=ttyAMA0 panic=-1 -- NAME"`, without the
host link: the kernel hands what follows `--` to `/init` as its
arguments, which it passes on, so the benchmark's name reaches `erx_peer_bench` as its one
argument. The generic timer's counter is readable from user mode, and
the `CLOCK` line reads it at 24 MHz under HVF, so Linux's cells are on
the `counter` clock as erXos's are. The serial log is read as erXos's is (`NativeBench.guest_lines`).
The kernel's own messages share the console; one that lands inside a
`BENCH` line makes that line `rejected`, which is visible and fails safe.
`panic=-1` makes a crash of process 1 end the boot at once instead of at
the deadline (both parameters' behaviour is unverified, from no source
read).

**In a session.** Linux's guest (`LinuxGuest::Guest`,
`tools/lib/erx/linux_guest.rb`) builds the initramfs once per session and
boots in one CPU and in the landing boot's count. `erx_peer_bench` is
built with the landing profiles, so the guest refuses `--profile full`,
and it refuses a session while its lock is not fetched, naming the
fetch. The program prints a line for every cell of the boot, a
counterpart's timing or `unsupported` with its reason, so its record
keeps each one.

### Linux's Erlang guest

The Erlang table of [Counterparts](#other-systems-on-the-same-raspberry-pi-4)
sets erXos's `xdomain` cells beside stock OTP 29.1.2 on the same Linux
kernel in the same environment: E-D1's same-node and loopback-distribution
baselines ([design-domains.md](design-domains.md#performance)), measured
in the machine erXos's numbers come from. It is a second Linux boot of the
session, with its own initramfs; the C cells' boot is unchanged.

**OTP.** Stock OTP 29.1.2 is built by the Linux oracle
([design-host-oracle.md](design-host-oracle.md)): the tarball `deps.lock`
pins, configured and built in the `oracle-toolchain-arm64` image (Debian
bookworm, its gcc) in the oracle's offline container, exactly as the
oracle builds it (`build_stock`, `tools/lib/erx/oracle_guest.rb`), in the
flavour of the erXos image it is set beside. On the Apple Silicon host
that image's build is an AArch64 Linux build against bookworm's glibc.
The oracle keeps its installed tree inside the container's volume, so
the guest needs one more export of it
([Native workspace and artifact export](design-host-oracle.md#native-workspace-and-artifact-export)):
the installed tree at its prefix, `/tmp/erx-oracle/install`, and the
shared libraries its programs (`beam.smp`, `erlexec`, `erl_child_setup`,
`epmd`, `inet_gethost`) and its NIF libraries load, listed by the image's dynamic loader in the
workload phase and copied, with their paths, by the exporter, which runs
no stock program. Alpine's package is not used: Alpine 3.24's community
repository for aarch64 offers `erlang27` 27.3.4.19 and `erlang28`
28.5.0.8, and no OTP 29 ([References](#references)).

**The initramfs.** What the two nodes load of the exported tree, at
its own prefix, so nothing is relocated: the five programs of its ERTS
directory; `bin/no_dot_erlang.boot`, the boot both nodes start with
(`-boot no_dot_erlang`, one name the host passes to `/init`'s build); the
`OTP_VERSION` of the boot's release, which in a stock install is the
file the identity line reads; and
every member of the code path the boot's `path` instructions set, read
from the boot itself (`LinuxErlangGuest.packed`). In interactive mode
the code server adds each `lib/*/ebin` it finds to that path, so an
application left out is one the nodes cannot load: a module the nodes
need and the boot does not name fails the boot rather than skewing it.
The boot's directories select only members of the export's inventory, and
one outside `$ROOT`, or with a `.` or `..` component, refuses the build.
Beside that tree the initramfs holds the libraries at the paths the loader
listed; the bench
modules' beams under `/bench/ebin`; `/etc/hosts` with the IPv4 loopback
line; `/dev/console` and `/dev/null`; and a launcher of its own as `/init`, `bench/linux/erlang_init.c`,
which shares its wait and power-off with the C guest's `/init`
(`bench/linux/launch.h`) and is built the same way, with the export's
ERTS directory, the boot's name and the beams' directory passed as build flags. The
export's logs and evidence stay out, and the record keeps the initramfs's
size (`initramfs_bytes`) beside its hash. Execute bits are derived, not
recorded: `/init`, the five programs of the export's ERTS directory and
the interpreter their `PT_INTERP` program header names, the dynamic
loader the kernel executes with each of them, get them; every other
member is `0644`, and `/tmp` is `1777`. An interpreter the export does
not hold, or a program that is not a 64-bit little-endian ELF file or
whose program headers name more than one interpreter or one outside
the file, refuses the build; a program that names none is static. Process 1 mounts `/proc` and
`/sys`, brings the loopback interface up, starts `epmd -address
127.0.0.1` as its own child and waits until it accepts a connection or
ends,
then starts two nodes by executing `erlexec` directly with the
environment the `erl` script would give it (`ROOTDIR`, `BINDIR`, `EMU`,
`PROGNAME`) and nothing else, since the guest has no shell; epmd's and
the echo node's output go to `/dev/null`, so the console carries only the
client's lines and `/init`'s. It waits for the client under its deadline
(`LinuxErlangGuest::DEADLINE_SECONDS`), says how the client ended unless
it exited with 0, prints `erx: bench: done`, the line the host's last
checkpoint waits for, and powers the machine off.

**The nodes.** `bench_echo@127.0.0.1` and `bench_client@127.0.0.1`, long
names given as an address so no resolver is asked, one cookie,
`-start_epmd false`, `-kernel inet_dist_use_interface {127,0,0,1}`, and
the scheduler count of the erXos domain each is set beside: `+S N:N`,
N the boot's CPU count, which the host passes as `/init`'s second
argument and records as the run's `erts_schedulers`.
The guest has no network device, so the cookie guards nothing but the
design's seeded fault, whose `/init` gives the echo node another one. The carrier is distribution's default, TCP over
loopback (`inet_tcp_dist`; the kernel application's carriers are TCP over
IPv4 and IPv6, as read in the tree's copy, `otp/lib/kernel/src/`, and
TLS is the `ssl` application's). The client connects, makes
one untimed round trip, and runs `local-rtt` against an echo process of
its own node and `xdomain-pingpong` against the echo process registered
on the other node, one request outstanding at a time, the same 64-byte
`{echo, B}` as on erXos. Its standard output is process 1's console. Its
one argument, the benchmark's guest modules and their arguments as an
Erlang term (`XdomainBench.guests`, the echo `{erx_xdomain_echo,
'bench_echo@127.0.0.1'}`), is what the kernel hands `/init` from after
`--` on its command line, a single word without spaces or double quotes,
so the initramfs does not depend on the cells a boot asks.

**The same modules.** `bench/erx_xdomain_bench.erl`, `bench/erx_bench_hist.erl`
and the Erlang line writer are the ones erXos's image runs, compiled for
this guest by stock OTP 29.1.2's `erlc` on the host
(`build/oracle/<flavour>/install/bin/erlc`, which `make oracle-bootstrap`
builds), so no beam compiled by erXos's modified OTP is loaded by stock
OTP. The module's one difference by system is where its echo is: a
connection to `erx_echo_test`'s facet on erXos, a registered name on the
peer node here. Its lines are the same `BENCH` and `CLOCK` lines, in
clock `monotonic`, each request's encoded size recorded as each side's
path measures it. Its first line is the oracle's own identity line,
`ERX_ORACLE <version> <flavour>`, and a boot whose line is not 29.1.2 in
the expected flavour is refused.

### L4Re's guest

**Sources.** Upstream Fiasco at exactly the revision erXos's fork came
from, the `Revision` line of `fiasco/kernel/ORIGIN.md`, unpatched, so
the fork's one pin moves both kernels; L4Re's repositories at the
commits each was at on that revision's commit date; and ipcbench
(`github.com/l4re/ipcbench`) at
`148682322103a984ddf84eb1a28e67a3d50c0b28`, the commit its facts record
read, its last commit before the commit date of the fork's revision
(`fiasco/kernel/ORIGIN.md`); a later revision re-checks that ipcbench has no newer commit
before its date. Each is a `git` source pinned by its commit and the
SHA-256 of git's tar of that commit, in L4Re's own lock,
`bench/l4re/deps.lock`, in `deps.lock`'s form. Only `tools/erx fetch
--l4re` reads it, as only `--example` fetches an example: a default
fetch does not clone L4Re, and a `--cache` fetch does not need it. That
fetch publishes each tree under `build/l4re-sources`, a root of its own
(`tools/lib/erx/l4re_fetch.rb`), and the container build copies each in at
the path L4Re's manifest (`github.com/L4Re/manifest`, `default.xml`) gives them:
`l4` for `mk`, `l4/pkg/<name>` for packages, `fiasco` for the kernel,
and `l4/pkg/ipcbench` for ipcbench. The build needs no package of the manifest
beyond `mk`, `l4re-core`, `bootstrap`, `libfdt` and `drivers-frst`:
with those and ipcbench, L4Re's make skips only `ned-prompt`'s variant
that needs readline, which ipcbench's image does not load. Ham, the
manifest's own tool, is not used: the fetch step does its one job. The
published snapshot (`l4re-snapshot-26.09.0`) is not used, because which
Fiasco revision it carries is unverified.

**License and clean room.** ipcbench's `.c` files, `ipc_common.h` and
`conf/ipcbench.cfg` state `SPDX-License-Identifier: MIT`; `measure.h`,
the Makefiles, `conf/modules.list` and `Control` state no license, and
the repository has no license file ([the facts record](#references)).
MIT lets erXos build, run and modify those files, and redistribute them
with their notice. The unmarked files grant nothing in writing, so
erXos redistributes neither them nor anything built from them: ipcbench
is fetched, built out of the tree and run inside a guest, a test tool
that is never shipped, as the dependency rules allow for a tool of any
license. Building and running the unmarked files on that footing, as a
test tool that is never shipped or redistributed, is accepted. Because `measure.h`
holds the counter reads and the iteration count, erXos's agents read
ipcbench only through a facts record written by a separate agent that
alone read its source; the importer and the counterpart lines are written
from that record, and the importer's fixtures are lines erXos writes in
the format the record gives, not captured output. l4re-core's source is
never read. L4Re's page says its numbers are means over tens of
thousands of calls, read from the cycle counter on Arm, with Fiasco in
its `CONFIG_BENCHMARKING=y` configuration.

**Build.** L4Re's own build system, run as its documentation describes
and as a black box: for `arm64` from L4Re's own `arm64-virt-v8a`
defconfig, then the target `elfimage E=ipcbench` with
`PLATFORM_TYPE=arm_virt`, `MODULE_SEARCH_PATH`
naming the Fiasco build and ipcbench's `conf` directory, and
`MODULES_LIST` its `conf/modules.list`; the image is
`images/bootstrap_ipcbench.elf`.
Its makefiles, scripts and the helper programs it builds are code fetched
from elsewhere, so they run only inside the oracle's container
([Container boundary](design-host-oracle.md#container-boundary)): no
network, no capabilities, a non-root user. `tools/erx build l4re`
(`tools/lib/erx/l4re_build.rb`) creates the container from the pinned
arm64 toolchain image and copies the fetched trees, the tool packages
and its script (`bench/l4re/build.sh`) into it before it starts, rather
than mounting them: the copies belong to root, so the build cannot write
its sources. The container is created with the oracle's confinement
flags (`OracleContainer::CONFINEMENT`: no network, an init, private IPC
and cgroup namespaces, no capabilities or privilege gain, no engine log,
restart or health check), its swap bounded by its memory and its script
started under `env -i`, and the engine's own inspection of it must show
it offline, unprivileged and unmounted before anything is copied in.
Every command names the engine by its socket, which
`Dependencies#local_docker_connection` requires to be a local UNIX
socket, so no TCP or SSH endpoint and no `DOCKER_*` variable chooses
another. The engine is arm64 and runs the image natively: Docker on the
Apple Silicon development host. Under an x86-64 engine's user-mode
emulation (qemu-aarch64 7.0.0) gcc segfaulted at random, a few compiles
in every pass of Fiasco's and L4Re's builds, so there the build fails at
random rather than running slower.
The build runs in the container's own filesystem. Its attached log is
bounded at 64 MiB, and `/tmp/out` comes back as the tar archive
`docker cp` streams, bounded as it is written: `bootstrap.elf`,
`globalconfig.out`, L4Re's resolved `.kconfig` and the compiler's
version line are unpacked from it only when it holds exactly those, each
a regular file within its bound, and read only when its text is
printable ASCII. That is what keeps the build offline and off the host;
nothing of L4Re runs on macOS. The compiler is the image's gcc for AArch64
Linux, without a cross prefix. The image has GNU make, Perl and m4 but
not flex and bison, which the kconfig of both Fiasco and L4Re builds,
nor gawk, which L4Re's build requires by name, with its library
libsigsegv; they come from Debian bookworm arm64 packages pinned in L4Re's lock by
their `snapshot.debian.org` URL and SHA-256, fetched by `fetch --l4re`,
and unpacked by the build, as its non-root user, into a tools directory
on its `PATH`, never installed and never fetched during the build. erXos's fork is built by clang, so the two kernels come from
different compilers, which both subjects record. The kernel is
configured from erXos's `config/fiasco/kernel.defconfig`, so the two
kernels differ by the fork's patches and their compilers: the comparison
is of the kernel configuration erXos runs, not of L4Re's published one.
That file sets `CONFIG_PERF_CNT_USER`, which ipcbench needs on Arm.
Upstream Fiasco keeps every setting of it, and the record keeps the
resolved `globalconfig.out` and its difference from erXos's, which a
later revision of either may make nonempty.
Nothing of L4Re enters the tree.

**Boot and import.** `QemuPlan.argv` with `-kernel` the built
`bootstrap.elf`, no command line, in the session's one-CPU form only:
ipcbench pins none of the threads of the programs the comparison reads
(`syscallbench`, `ipcbench`, and `ipcclient` with `ipcserver`), so one CPU
is the only form in which their placement is known, and its parallel
programs, whose CPUs all load each other, are not read. L4Re's
`l4image ... launch`, which starts its own QEMU, is not used, so L4Re's
QEMU arguments are erXos's. The guest does not halt: the boot ends at a
checkpoint on its configuration script's last line, `Benchmarks done.`,
and QEMU is then ended as at a deadline. The session's boot step passes
the log's lines to the importer, a pure function from lines to cells,
and writes the run with the subject the build gave. ned prints each line a
program writes behind its log tag (`sc:single`, `ipc:1AS`, `ipc:2AS`),
cut or padded to eight columns and followed by `| `, so `sc:single`'s
lines begin `sc:singl| `, and wraps each write in the color its
configuration names, a Select Graphic Rendition sequence before it and a
reset after, so a line written in two writes carries them in its middle
too. The importer drops those color sequences, and no other control
sequence, before it reads a line. A program's result is one line
`CPU <n> done <count> <operation>s in <total> cpu-cycles, <mean>
cpu-cycles/<operation>`, timed over 10,000 calls with no warm-up. The
importer requires a count of 10,000 for `syscall` and 20,000 for `IPC`,
since ipcbench counts each call's request and reply as two IPCs, and a
printed mean equal to the total over the count, truncated. Each row is a
`mean` cell in clock `cycles`: 10,000 calls, the total, and the printed
mean, which for IPC is half a round trip and is shown as printed; the
side-by-side table shows the total over 10,000, one round trip, beside
erXos's round trips, and never halves erXos's. A program's error line
(`caller: ipc err`, `IPC error`) makes its cell `failed`; a line the
importer cannot read is `rejected`; a declared counterpart no line
reports is `not_run`. ipcbench reads the cycle counter register in user
mode and first sets its filter to count in the hypervisor's level too.
Under HVF, with `-cpu host`, the guest programs and reads that counter
and it advances, so the rows are measured; what it counts there, the
core's cycles or QEMU's model of them, is unverified, which is one more
reason its rows set no ratio.

### What HVF does to fairness

The three guests share one host, one QEMU and one virtual machine shape.
A shared shape does not make their paths through HVF the same: each
kernel meets the timer, idle, interrupts and first touches its own way.
The numbers are therefore observations of these virtual machines, not
estimates of what the same kernels cost on the bare core. Each difference
is recorded, never corrected:

* **Clocks.** erXos's guests and `erx_peer_bench` read the
  architecture's virtual counter in user mode, at the frequency its
  register gives (24 MHz under HVF on the primary host,
  [research-baselines.md](research-baselines.md#exception-and-address-space-switch-costs)),
  so their ticks are the same clock, about 42 ns each, and short
  operations are batched by [the rule](#the-one-clock). erXos's read is
  `erx_fiasco_counter`; that Linux lets user mode read the counter is
  unverified, and where it does not `erx_peer_bench` reads
  `CLOCK_MONOTONIC`, clock `monotonic`, as stock ERTS's stamps on Linux
  always are. ipcbench reads the cycle counter, clock `cycles`, which is
  why its rows set no ratio.
* **What leaves the guest.** System calls, exceptions and address-space
  switches are expected to run on the host's core without an exit, except
  where a guest's path touches a register HVF traps (unverified for all
  three). Timer programming, interrupts and `WFI` go through HVF and
  QEMU, so every wake and deadline includes the host's part. Whether
  QEMU's interrupt controller under HVF is its own emulation or the
  host's is unverified, and is the same for all three.
* **The host's scheduler.** Each vCPU is a QEMU thread that macOS places
  on any core, performance or efficiency, as it chooses; nothing pins
  it ([Environments](#environments)). The rounds' turning order keeps
  that drift from following one system's position and the record shows
  it; neither settles it.
* **First touch.** QEMU allocates guest memory as the guest first
  touches it, so a guest's first write to a guest-physical page faults
  in the host too. `vm` cells that land on fresh pages include that,
  and how often they do depends on how each kernel reuses its frames.
  erXos's QEMU arguments stay as its own cells use them.
* **Each kernel's own defaults and compilers.** Linux runs its
  distribution's configuration and its own choice of mitigations, which
  its boot log records; L4Re's Fiasco runs erXos's configuration; erXos
  runs as built. Linux's kernel is the distribution's build, with its
  compiler; erXos's Fiasco and `erx_peer_bench` are built by erXos's
  clang, and L4Re and stock OTP for Linux by the oracle image's gcc.

### Open decisions of the comparison

* **Which Linux.** Alpine's `virt` kernel is a stock kernel trimmed for
  virtual machines, not the generic kernel most systems run; Ubuntu
  26.04's generic kernel is already pinned for
  [F2FS's distribution guest](design-f2fs.md#the-distribution-guest).
  Recommendation: Alpine alone now, and Ubuntu's kernel as a second
  Linux row only if a cell's result would change a decision.
* **The board's Linux binary.** The board's Linux row compiles
  `erx_peer_bench` on the board. Recommendation: carry the same static
  binary instead, so both forms run one file and the board needs no
  compiler.
* **L4Re without a cycle counter.** If ipcbench cannot time under HVF,
  L4Re's VM rows are `unsupported`. Recommendation: accept that and
  compare L4Re on the board, rather than write an erXos program for
  L4Re, which would need L4Re's headers that the clean room keeps
  closed.
* **L4Re's compiler.** The container that keeps L4Re's build off the host
  and offline has gcc, not erXos's clang, so L4Re's Fiasco and erXos's
  fork come from different compilers. Building on the host with clang,
  as L4Re's macOS page describes, would run L4Re's makefiles and helpers
  as the developer with nothing enforcing offline. Recommendation: the
  container, with the compiler recorded; a clang toolchain image for the
  container only if a `nullcall` difference between the two Fiascos would
  change a decision.
* **A Unix-domain socket carrier.** OTP's kernel application has no
  distribution carrier over Unix-domain sockets (read in the tree's copy;
  whether stock's source ships one as an example is unverified), so such a row would run an erXos-written
  distribution module, not stock OTP, and isolate only how much of
  `xdomain-pingpong` on Linux is TCP over loopback. Recommendation: no
  such row; TCP over loopback is what a stock node uses and what E-D1's
  baseline names.

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
| L4Re | a pinned L4Re snapshot of the Fiasco revision erXos's fork came from, built by its own build system, without virtualization support as erXos's fork is | netboot, as erXos's Fiasco does | L4Re's own IPC benchmark (`github.com/l4re/ipcbench` at `14868232`, as in [L4Re's guest](#l4res-guest)); in the configuration erXos's fork uses, which is the comparison, and in L4Re's published configuration as a diagnostic: a printed per-IPC mean, half a round trip, more than a tenth from the page's 505, 702 and 305 cycles is reported beside the comparison and looked into, and does not by itself void it |
| Linux | Raspberry Pi OS Lite, 64-bit, pinned, with the vendor's stock kernel; its real-time kernel as a second row for `wake` only, if the image offers one (unverified) | its own SD card | `erx_peer_bench` |

Each image is fetched by the fetch step at a pinned URL and SHA-256, and
written to its own card; nothing from it enters the tree, and nothing of
it runs on the host. A system's frequency governor is set to hold the
configured frequency, and how each system is told so is checked on the
board.

`bench/peer/erx_peer_bench.c` is one C17 file under erXos's license that
Linux compiles on the board with its own compiler; the record
keeps the compiler's version and flags. It runs the POSIX counterpart of
each operation and prints the same `BENCH` lines, so one reader imports
every system's. It reads the system counter directly where the system
lets user mode read it (unverified; recorded as clock `counter`),
and otherwise `CLOCK_MONOTONIC` (clock `monotonic`). It pins threads with
`sched_setaffinity`, and its
`wake` handshake reads the waiting thread's state from Linux's `/proc`;
those are the places it differs by system.

A run of another system on the board writes its console to a file
through the host's serial adapter, and `tools/erx bench import NAME --env
pi4-4gb-SYSTEM LOG [--subject FILE] [--capture FILE]` turns the log, and the analyser's
capture, into a record; an erXos log goes through the same command with
the queue it was a walk of ([Importing a log](#importing-a-log)). The subject file is the build record the system's package wrote
when it built the card's image: its pins and their hashes, the image's
SHA-256, the resolved configuration, the toolchain and the boot
arguments. Without one, every `subject` field the log does not state is
`unknown`; none is filled in from the harness's own tree. L4Re's lines go
through the importer of [L4Re's guest](#l4res-guest), as `mean` cells.

**Counterparts.** Each declaration names, per operation, what the other
systems run, and the side-by-side table prints that line with the numbers.
The two tables below and the program table of
[What a program sees](#what-a-program-sees-posix-and-erl) are the one
list for the board and for
[QEMU under HVF](#other-systems-in-qemu-under-hvf) alike, one for each
layer. The kernel table sets the kernels' own paths beside each other:
its erXos cells are the root task's and its test tasks' calls of
`liberx`, beneath any program, with no Erlang on the path, so a row of
it is kernel against kernel, not what a program on erXos pays for the
POSIX call in its Linux column. The Erlang table sets the runtimes'
messages beside each other, and the program table a program's calls. What ipcbench's programs measure
comes from its facts record ([L4Re's guest](#l4res-guest)), not from
their names. On the same CPU means both threads pinned to one CPU, and
under HVF every thread in the session's one-CPU form.

The kernel table:

| erXos operation | L4Re | Linux | What differs |
| --- | --- | --- | --- |
| `nullcall.kernel` | `syscallbench`: an IPC call to the caller's own thread capability whose thread-control operation returns early | `getppid` | three entry paths, not one null call. erXos's cell is the same act on erXos's Fiasco ([`nullcall`](#3-nullcall-the-decoder-refusal-round-trip)), so those two differ by the fork's patches and compilers; `getppid` is a POSIX call doing its own small work. A program on erXos enters no kernel for `getppid` or `getpid`; what it pays for such a call is the program table's `posix.getpid` |
| `nullcall.root-same-space` | `ipcbench`: two threads of one task; a blocking call with an empty message to a responder already waiting in reply-and-wait | two threads of one process: an 8-byte request and an 8-byte reply over a pair of pipes, each read blocking, the echo thread on CPU 0 for `service-cpu` and on the last CPU for `other-cpu`, as the next row's echo process is | erXos's round trip carries one word to the root service and adds its receive, decode and refusal in user mode; L4Re's is an empty call to a waiting thread, the best case; a pipe round trip is two writes and two blocking reads. Each row is its own endpoint: no difference of two rows isolates the root service |
| `nullcall.root-cross-space` | `ipcclient` and `ipcserver`: the same between two tasks | the same between two processes | the same, with an address-space switch each way |
| `wake.wake-same-cpu`, `wake.wake-cross-cpu` | none | thread B waits for a sequence word to change in `pthread_cond_timedwait`, its absolute deadline 1 s away on `CLOCK_MONOTONIC`; thread A, on B's CPU or another, takes the mutex, reads B's state in `/proc/self/task/<tid>/stat` until it is `S`, stamps, changes the word, signals, releases and blocks reading a pipe; B stamps its return and writes the pipe | B returning with the word changed is the wake, and `ETIMEDOUT` a lost wake. The blocked state is the kernel's report where erXos's is its park record |
| `wake.park-deadline` | none | `clock_nanosleep` on `CLOCK_MONOTONIC` with `TIMER_ABSTIME` at the phase sweep's deadlines, period 1 ms | the systems' timer resolution |
| `wake.gpio-edge` | none | a process blocked on a GPIO line's event, writing a second line (Linux's GPIO character device) | every system on the analyser's clock |
| `vm.commit`, `vm.touch`, `vm.commit-touch` | none | anonymous private `mmap` of the same page counts; the first write to each page of a fresh mapping; both in one interval | erXos's commit may map pages at once where POSIX maps at the first touch, so commit alone and touch alone are not one act on both; `commit-touch` is the endpoint both share |
| `vm.protect`, `vm.decommit` | none | `mprotect` to read-only and back; `madvise(MADV_DONTNEED)` of the range | after the timed loop each runs erXos's untimed checks, a decommitted page reading zero among them, so an advice that keeps the page's contents makes the cell `failed` rather than a cheaper number |
| `vm.map` | none | `shm_open` and `ftruncate` to create, `mmap` to map, `munmap` to release, `close` and `shm_unlink` to destroy, each timed | erXos's object is a capability; POSIX's has a name |
| `sched.share-equal` | none | the same spinners of one process, pinned to the same CPU index, with the same windows, under the default policy at the default priority | the scheduler; its default policy is part of the result |

The Erlang table, where L4Re has no row:

| erXos operation | stock OTP 29.1.2 on Linux | What differs |
| --- | --- | --- |
| `xdomain.local-rtt` | two processes of one node, the same module and message ([Linux's Erlang guest](#linuxs-erlang-guest)) | erXos's ERTS against stock |
| `xdomain.xdomain-pingpong` | two nodes, two OS processes, over distribution's default carrier, TCP over loopback; the echo process is registered on the other node | stock encodes the message into a TCP stream through the kernel's loopback; erXos's passes the funnel and the facet's admission into a lane. Both cross from one isolated space to another |

On the board, the Erlang table's rows run where a board package brings
stock OTP 29.1.2 to the system; until then they are `none`.

seL4's published numbers stay context: seL4 is not among the systems
approved to boot on the board.

### L4Re on the board

L4Re's board guest is the guest of [L4Re's guest](#l4res-guest), from the
same lock, container and kernel configuration, built for the board as
erXos's own Fiasco image is built for it ([design-fiasco.md](design-fiasco.md#the-raspberry-pi-4)):
`tools/erx build l4re --platform raspi4b` configures L4Re from erXos's
`config/fiasco/user-raspi4b.defconfig` (Fiasco's generic platform,
`arm_gen`, which reads the memory map, the console's UART and PSCI's
calling method from the device tree, position-independent as
`mk/platforms/arm_gen.conf` requires, with the PL011 and 16550-family
UART drivers) and makes the target `rawimage E=ipcbench
PLATFORM_TYPE=arm_gen`, whose `images/bootstrap_ipcbench.raw` comes back
as `bootstrap.raw` with its build record in `build/l4re-raspi4b`
(`L4ReBuild::TARGETS`). Fiasco is configured from
`config/fiasco/kernel.defconfig`, as erXos's board kernel is, so the
board's two kernels again differ by the fork's patches and their
compilers. Fiasco's own `rpi` platform is not used, as erXos's board
build does not use it.

**Boot.** The image is the bootable file of a bench set laid out as
erXos's are (`BootPartition.lay_out_set`): the same pinned firmware,
BL31, device tree, overlays and `config.txt`, frequencies,
`kernel_address` and `total_mem` among them, so the two systems' boot
sets differ by `kernel8.img` alone, and each record keeps every file's
SHA-256. The firmware loads it at `0x200000` and BL31 enters it there;
a position-independent `bootstrap` runs where it is loaded. The set is
netbooted through the HTTP form as a walk's queue is: one entry for
L4Re and the found target's pair as the way back (`Netboot.prepare`
with the found target, under the stager's lock), the link pointed at
the queue while the board runs and back at the found target when the
run ends. The console log from the reboot to `Benchmarks done.`, or to
a deadline of 300 seconds, is the run's log. L4Re does not reset the
board, so the run does what a person at the console would: it types
Fiasco's kernel debugger's reboot on the console it holds, a key a
second: ESC, `^`, and the Return the debugger asks for to confirm it
(`Return reboots, "k" enters L4 kernel debugger...`), and waits for erXos's banner from the way-back
entry, within the boot deadline of [the walk](#the-walk). The debugger
is in the image because erXos's kernel configuration leaves Fiasco's
`JDB` at its default, which is on; the run's deadline types the reboot
too, since the debugger may still answer when ipcbench has not
finished. A board that shows no banner by then is left to a person: the
run says so, the link names the found target again, and a power cycle
brings the board back on it. Nothing of erXos enters L4Re's image. The
run is `tools/erx bench NAME --env pi4-4gb-l4re --console
DEVICE|tcp:HOST:PORT --ssh DEST --key FILE [--http DIR]` (`L4ReBoard`),
whose console is the one [the walk](#the-walk) reads, a device or the
Glasgow's TCP port, written through `BoardConsole#type`; when ssh
cannot ask erXos to reboot into the queue, the run types `reboot` on
that console as the walk does, and a console that cannot be written
ends the run as closed, the link pointed back.

**Import.** `tools/erx bench import NAME --env pi4-4gb-l4re --subject
FILE LOG` makes the record from that log and the build record of
`build/l4re-raspi4b`, the importer of [L4Re's guest](#l4res-guest)
giving its cells; the environment is `pi4` with system `l4re` and one
CPU. ipcbench pins none of the threads the comparison reads, so, as
under HVF, one CPU is the only form in which their placement is known:
the set's device tree keeps only the boot CPU's node, so Fiasco starts
no other CPU: `BootPartition.lay_out_set` with `boot_cpu_only` removes
every other `cpu@N` node from a copy of the board's tree
(`BoardTree.boot_cpu_only`), and the set's record says so
(`board_tree_cpus`). Fiasco's generic platform honours it: on the board
it starts only CPU0, and ipcbench finds one CPU. Fiasco prints a line for each
CPU it starts (`CPU0: ID_PFR...` for the boot CPU, `CPUn booted (same
IDs as CPU0).` for another); a log that names more than one is not
imported. The import prints the board's side-by-side table: the record
beside erXos's newest board record of the benchmark, each system in its
own form, erXos on four CPUs and L4Re on one, so the rows name no CPU
form (`BenchSideBySide.tables` with `forms: false`).

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
  it is never in step with a timer's rhythm, such as Fiasco's 1 ms RCU
  interrupt;
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

## What a program sees: `posix` and `erl`

The kernel table sets erXos's root task and test tasks, calling `liberx`
directly, beside Linux's system calls and L4Re's IPC: on erXos it is
Fiasco's IPC and the root service's decoder, nothing a program crosses
on its way to a file or a pipe, and no Erlang. A POSIX program such as
Doom never makes those calls. It calls `open`, `read`, `pipe`,
`posix_spawn` and `mmap`, and on erXos each goes from musl through
`liberx`'s program layer to the service that owns it, mostly Erlang in
the program's own session: its handler, the open-file description, the
file server of the path's grant, the session's pipe server. Linux
answers the same calls in its kernel. Setting `nullcall.kernel` beside
`getppid` says what erXos's kernel costs, not what a program on erXos
pays for `getppid`. This section measures the second thing: ordinary
UNIX system calls and UNIX IPC as a program issues them, the same
program on erXos and on the other systems, compared row by row.

### The construction: one program, every system

`erx_peer_bench` gains one benchmark, `posix`, whose operations are POSIX
calls and nothing else, and on erXos it runs as a program of a session,
built against erXos's musl. The same C file, compiled by the same
compiler with the same code-generation flags, runs on every system that
has the call, so a row's act is the program's act by construction and
only the system beneath it differs. Everything after the program's line
is the existing construction: its `BENCH` and `CLOCK` lines go through
`BenchMeasurement`, each boot is a run written by `BenchRecord.write`, a
comparison session boots each system in turn in its rounds, and the
side-by-side table prints a third table, the **program table**, beside
the kernel table and the Erlang table. Nothing is compared across
systems; the table sets them beside each other.

What runs on erXos is derived, not declared. Before its timed loop each
cell makes its calls once, untimed; a call that answers `ENOSYS` or
`ENOTSUP` makes the cell `unsupported` with that call and its `errno`
named as the reason (`unsupported: stat answered ENOSYS`), the
status the record already has for an operation the environment lacks.
The rows that wait on an unbuilt part therefore report so from the
system itself, a row measures once its part exists, and no list of
which rows run is kept anywhere to fall out of date. The statuses below
are read from the code and are the expected output of that first probe.

The Erlang twin is `erl`, a module of its own beside `erx_xdomain_bench`
(`bench/erx_erl_bench.erl`), which runs on erXos's ERTS in the
`xdomain` bench image and on stock OTP 29.1.2 in Linux's Erlang guest
([Linux's Erlang guest](#linuxs-erlang-guest)), through
`bench/erx_bench_hist.erl` and the same lines.

### Which systems, and what each compares

| System | What runs | Which table |
| --- | --- | --- |
| erXos | `erx_peer_bench posix` as a program of root's session; `erl` in the `xdomain` bench image | all three |
| Linux | the Alpine guest of [Linux's guest](#linuxs-guest), with `erx_peer_bench` linked statically against the prebuilt `libc.a` of Alpine's pinned `musl-dev`; erXos's program links erXos's own build of the tree's musl, whose `erxos` files replace some routines (`posix_spawn` among them, `musl/src/process/erxos/posix_spawn.c`). Both are musl-derived and neither is the other's code; each record keeps its build's identity, the package pin on Linux and the C library's build on erXos. Stock OTP in its Erlang guest | all three |
| L4Re | ipcbench only | the kernel table only: L4Re's POSIX layer is too thin to run the program set, so every program row says `kernel rows only` and names the kernel row nearest it, if any |
| Genode | `erx_peer_bench posix` built against Genode's C library, on each kernel Genode's guest is built for ([Genode's guest](#genodes-guest)) | the program table: the microkernel operating system whose programs, like erXos's, reach their files and pipes through services in user mode |

### Fairness

* **The same source, compiler and flags.** erXos's program and Linux's
  binary are one C file, compiled by erXos's clang (`ERX_CLANG`) with one
  list of code-generation flags read by both builders from one definition,
  `NativeRoot::CODE_FLAGS` without its target. The erXos build compiles
  the file as `NativeRoot` compiles its `FP_SOURCES`, without the
  `-mgeneral-regs-only` that its `FLAGS` add to every other task's C
  (`tools/lib/erx/native_root.rb:188-190`, `:336`), so neither build
  forbids the compiler a register the other may use; warnings and include
  paths may differ, code generation may not. The target, its headers and
  its C library differ, a musl-derived one on each. Genode's
  build uses Genode's own tool chain, GCC, which its documentation
  requires (References), so its rows differ by compiler too, which the
  record keeps.
* **The same machine.** The same QEMU, accelerator, CPU count and memory
  in a session, as [A comparison session](#a-comparison-session) gives
  every system; on the board, the same Raspberry Pi 4 under the rules of
  [Other systems on the same Raspberry Pi 4](#other-systems-on-the-same-raspberry-pi-4).
  HVF and board numbers are never in one table, since their environments
  differ in kind.
* **Distributions, not one number.** Medians, 99th percentiles and
  maxima over the session's boots, in the records every run already
  writes; the side-by-side table shows each boot's summary.
* **Every row says what it is.** Each operation's declaration states
  `same act`, when both systems do the same work for the call, or
  `nearest counterpart`, with the one line of what differs, and the
  program table prints it; a declaration without one is refused.

### The program's clock and placement

On erXos the program reads the counter through `erx_fiasco_counter`, the
one read of the counter a linked erXos program may make, which the
build's check of every program enforces
(`liberx/backend/fiasco/arch/aarch64/clock.c`, `CounterReads`,
`tools/lib/erx/counter_reads.rb`), and its frequency through
`erx_fiasco_counter_hz`. It does not probe: the probe catches the trap a
refused read raises, and a program on Fiasco catches no signal
(`liberx/backend/fiasco/program_task.c:87-92`). Linux keeps the probe it
has; Genode reads `CLOCK_MONOTONIC`, clock `monotonic`, whose resolution
there is unverified; the batching rule of
[the one clock](#the-one-clock) counts the clock's observed increments,
so a coarse one batches more, and a cell too short for it shows so by
its batch and its `total`. The
program does not ask the system how many CPUs it has: on erXos musl's
`sysconf(_SC_NPROCESSORS_ONLN)` answers 1, since `sched_getaffinity` is
not offered and musl counts the mask it starts with
(`musl/src/conf/sysconf.c:203-210`,
[design-fiasco.md](design-fiasco.md#musl-over-the-backend)). The run
declaration's environment gives the CPU count, and the host passes it as
the program's second argument on every system, so the CPUs a cell
places its threads on, and the pair its `CLOCK` line calibrates, come
from the boot the host made. Threads are
pinned with `sched_setaffinity` on erXos as on Linux: musl's erXos seam
offers it, a mask's first word (`musl/src/internal/erxos/syscall.c:295-301`,
`:499-500`). A cell whose stamps are taken by two processes (`spawn-main`)
runs in the one-CPU form only; `mutex-handoff` stamps across CPUs under
the cross-CPU rule; every other cell stamps in one thread, same-CPU
cells come from the one-CPU form and cross-CPU cells from the four-CPU
form, as in a session.

### The operations and their paths

Each table gives the act, its correct result, its profile, erXos's path
as the code has it, whether erXos runs it, the Linux counterpart and
whether it is the same act, and L4Re's entry. Genode runs every row
through its C library and its own services; each Genode entry is
unverified until its guest runs, and its first probe reports it.

**Trivial calls.** Both `fast` and batched.

| Operation | Act and correct result | erXos's path | erXos runs it | Linux | Same act? | L4Re |
| --- | --- | --- | --- | --- | --- | --- |
| `getpid` | `getpid()`; the same positive value every call | musl's `getpid` (`musl/src/unistd/getpid.c`) reaches `__erx_syscall`, whose seam hands the call back (`program_task.c:165`) to a row that returns a constant (`syscall.c:485-486`): no kernel call and no `liberx` call. By design the value is the startup message's `pid` from `liberx`'s record ([design-fiasco.md](design-fiasco.md#musl-over-the-backend)); the code answers 1 in every program ([todo-shell.md](todo-shell.md)) | yes | musl's `getpid`, a system call | nearest counterpart: erXos reads a value in user mode where Linux enters its kernel; the row is what a program pays, not what a system call costs on erXos | kernel rows only; `nullcall.kernel` beside `syscallbench` is the nearest |
| `clock-gettime` | `clock_gettime(CLOCK_MONOTONIC)`; returns 0, never decreasing | handed back by the seam (`program_task.c:160`) to `clock_gettime_call` (`syscall.c:231-245`), which reads the counter and scales it in user mode | yes | musl's aarch64 port looks up the kernel's user-mode `clock_gettime` (`musl/arch/aarch64/syscall_arch.h:74-76`) and falls back to a system call; that the static binary finds it is unverified | same act where Linux's user-mode path is taken: a counter read and a scaling on both | kernel rows only; none |

**Files.** On erXos every file call is a request on the program's
channel to its handler (`liberx/program/file.h`): a frame and the
handler's doorbell, `erx_prog_handler` and the open-file description's
process, a request to the server of the path's grant, the reply, the
program's doorbell and the event executor's wake of the worker, the
bytes crossing the 64 KiB slots of the data area
([design-programs.md](design-programs.md#performance)). The files are
in `/tmp`, which on erXos is the domain's `erx_ramfs` tree process,
Erlang ([design-tmp.md](design-tmp.md)), and on Linux the initramfs's
root, both in memory. A 64 KiB file of a known pattern is made untimed
before the cells. Reads and writes are timed as `pread` and `pwrite` at
offset 0, the same call with the offset given, so that every sample is
the same act and a batch needs no `lseek` between its samples.

| Operation | Act and correct result | Profile | erXos's path | erXos runs it | Same act? |
| --- | --- | --- | --- | --- | --- |
| `open`, `close` | `open` of the file read-only, then `close`, each timed; every `open` returns the same number, the lowest free, and after the loop one more `open` still returns it, so no `close` left a descriptor behind | fast | `erx_prog_file_openat` (`program_task.c:203-205`): the handler walks to the file, clones the fid and opens the clone with `lopen` ([design-programs.md](design-programs.md#descriptors-and-files)); `close` ends the open with `{file, clunk, Open}` | yes: the programs suite's `fileio` case makes these calls (`tools/lib/erx/programs.rb:79-82`) | same act; Linux resolves the path in its kernel |
| `fstat` | `fstat` of the open file; size 65,536 and a regular file | fast | `{file, getattr, Open}` (`liberx/program/file.h:94-104`) | yes | same act |
| `stat` | `stat` of the path; as `fstat` | fast | musl's `stat` is `fstatat` (`musl/src/stat/stat.c`), which on this port calls `newfstatat` (`musl/src/stat/fstatat.c:104`, `musl/src/internal/syscall.h:166-168`); the seam answers `ENOSYS` for it with `AT_FDCWD` (`program_task.c:313-318`) | waits on the program layer's path calls, `stat` as a file request ([design-programs.md](design-programs.md#the-program-protocol)) | same act |
| `read`, `write` | `pread` and `pwrite` of 4 KiB and of 64 KiB at offset 0; the count asked for, the read's bytes the pattern (checked after the loop) and the written bytes read back | fast | `erx_prog_fd_pread` and `erx_prog_fd_pwrite` (`program_task.c:239-244`): one request per 64 KiB slot (`liberx/program/file.h:68-80`), so both sizes are one request | yes | same act |
| `read-seq`, `write-seq` | a 16 MiB file read, and written, from start to end in 64 KiB calls, one interval each; every count full | expensive | as `read` and `write`, 256 requests | yes, in the `posix` image, whose `/tmp` is raised to hold the files ([How erXos runs the program](#how-erxos-runs-the-program)); the development manifest's 2 MiB would refuse them | same act |
| `copy` | the 16 MiB file read in 64 KiB parts and each written to a second file opened with `O_WRONLY`, `O_CREAT` and `O_TRUNC`, both closed, one interval; the copy reads back equal | expensive | as above; `O_TRUNC` reaches `lopen` (`liberx/program/file.c:92-93`). Neither side syncs: `fsync` answers `ENOSYS` on a held descriptor (`program_task.c:249`, `:301`) | yes | same act |
| `create-unlink` | in a fresh directory, 1,000 empty files created and then unlinked, one interval; every call 0 | expensive | creation is `lcreate`; `mkdirat` and `unlinkat` answer `ENOSYS` (`program_task.c:304-306`, `:318`) | waits on the program layer's path calls (`mkdirat`, `unlinkat`) | same act |
| `readdir` | `opendir`, `readdir` to the end of a directory of 1,000 entries, `closedir`, one interval; 1,000 names besides `.` and `..` | expensive | `O_DIRECTORY` reaches `lopen` (`liberx/program/file.c:52-53`, `:98-99`), and `getdents64` answers `ENOSYS` (`program_task.c:257`, `:301`) | waits on the program layer's directory reads ([design-programs.md](design-programs.md#descriptors-and-files)) | same act |

L4Re, for every file row: kernel rows only; none.

**UNIX IPC.** A peer process is the program itself, started with
`posix_spawn` and the descriptors it needs placed by its file actions,
in a mode given by its arguments, so peer and parent are one file on
every system; the peer pins itself on its own first line. A pipe on
erXos is made by the session's pipe server at the program's `pipe2`
request, untimed, and its bytes move through `liberx`'s ring in memory
the two programs share, one copy in and one out, with a doorbell only
when the other side sleeps ([design-pipes.md](design-pipes.md#performance));
Linux copies through a buffer in its kernel. Every round trip is stamped
by A alone.

`pipe-rtt`, `poll-rtt` and `pipe-stream` take a parameter `peer`:
`process`, as above, or `thread`, a second thread of the same program
with the same pipes, which erXos runs before `posix_spawn` has its
request and which, set beside the process form, separates a pipe's cost
from a switch between address spaces. Both forms are in the
declaration; the probe makes the process form `unsupported` until the
spawn runs.

| Operation | Act and correct result | Profile | erXos's path | erXos runs it | Same act? | L4Re |
| --- | --- | --- | --- | --- | --- | --- |
| `pipe-rtt` | A writes n bytes to pipe 1, B reads them and writes them to pipe 2, A reads them; n = 1 and 65,536, same CPU and across CPUs; every reply equals its request, whose first bytes carry its sequence number | fast | `pipe2` through the handler (the programs suite's `pipe` case, `programs.rb:76-78`); `read` and `write` on the ring; the peer through `posix_spawn`, which plans and then answers `ENOSYS`, since the program protocol has no `{spawn}` request (`liberx/program/spawn.c:44-50`) | the `thread` form, yes: `pipe2` runs, and a program's `pthread_create` is unverified, settled by the cell's probe; the `process` form waits on `posix_spawn`'s request | same act | kernel rows only; `nullcall.root-cross-space` beside `ipcclient` and `ipcserver` is the nearest, a kernel IPC, not a pipe |
| `poll-rtt` | as `pipe-rtt` with n = 1, each side blocking in `poll` for `POLLIN` before it reads; the same replies, and every `poll` reports `POLLIN` | fast | `ppoll_call` (`program_task.c:93-105`): a wait on the caller's wake word, which the event executor bumps when the end's doorbell rings ([design-programs.md](design-programs.md#the-posix-lite-personality)) | the `thread` form, yes: `pipe2` runs, and a program's `pthread_create` is unverified, settled by the cell's probe; the `process` form waits on `posix_spawn`'s request | same act | kernel rows only; none |
| `ctx-ring` | a one-byte token passed around a ring of N = 2 and 8 processes joined by pipes, each writing 0 or 16 KiB of its own memory before passing it on, all on one CPU; a sample is one round, and every process sees the token once per round | fast | as `pipe-rtt`, every pass a doorbell and a switch between address spaces | waits on `posix_spawn`'s request | same act: each system's pipe, scheduler and switch | kernel rows only; none |
| `pipe-stream` | A writes 64 MiB to B in 64 KiB writes, B reads it all and answers one byte; A's interval, same CPU and across CPUs; B's count and a checksum of the bytes equal A's | expensive | as `pipe-rtt`; the ring holds 64 KiB ([design-programs.md](design-programs.md#the-posix-lite-personality)) | the `thread` form, yes: `pipe2` runs, and a program's `pthread_create` is unverified, settled by the cell's probe; the `process` form waits on `posix_spawn`'s request | same act | kernel rows only; none |
| `socketpair-rtt` | as `pipe-rtt` with n = 1 over `socketpair(AF_UNIX, SOCK_STREAM, 0)` | fast | a socketpair end is the read end of one pipe and the write end of another, made by the pipe server, in the second tier ([design-programs.md](design-programs.md#passing-descriptors)); `socketpair` answers `ENOSYS` (`program_task.c:328-331`) | waits on the second tier's socketpair and on `posix_spawn`'s request | nearest counterpart: two pipes on erXos, a UNIX-domain socket on Linux | kernel rows only; none |
| `tcp-rtt`, `udp-rtt` | 64 bytes and back over `127.0.0.1`, one connected TCP socket or one UDP socket a side; every reply equals its request | fast | a socket is an open of the handler's table naming a socket's open-file description, the socket's owner at the network service, whose loopback interface is Erlang (`erx_net_loop`) ([design-network-stack.md](design-network-stack.md#the-interface-towards-posix-programs)); `socket` answers `ENOSYS` (`program_task.c:328-331`) | waits on programs' sockets and on `posix_spawn`'s request | same act | kernel rows only; none |
| `tcp-stream` | 64 MiB over one loopback TCP connection in 64 KiB writes, the reader answering one byte at the end; A's interval; the reader's count and checksum equal | expensive | as `tcp-rtt` | waits as `tcp-rtt` | same act | kernel rows only; none |

The other UNIX forms of IPC get no row. A named UNIX-domain socket, POSIX
shared memory objects (`shm_open`), POSIX message queues and System V's
IPC are named by no design document for programs; memory shared between
programs is the second tier's `MAP_SHARED` across `fork`
([design-programs.md](design-programs.md#the-posix-lite-personality)),
which is no round trip of its own. A design that adds one adds its row.

**Threads and time.** Two threads of the program.

| Operation | Act and correct result | Profile | erXos's path | erXos runs it | Same act? | L4Re |
| --- | --- | --- | --- | --- | --- | --- |
| `mutex-handoff` | B says it is about to lock a mutex A holds; A waits 100 us, stamps and unlocks; B stamps when its lock returns; across CPUs, under the cross-CPU rule of [the one clock](#the-one-clock); B always gets the lock | fast | musl's mutex over `futex`, which the seam hands back (`program_task.c:158`) to `erx_umtx_wait` and `erx_umtx_wake` (`syscall.c:90-104`): `liberx`'s wait table and the waiter's semaphore in the kernel (`liberx/backend/fiasco/umtx.c`) | yes; that a program's `pthread_create` runs is unverified, settled by the cell's probe | same act; whether B spins or sleeps is each system's own choice and part of its result | kernel rows only; none |
| `cond-pingpong` | A and B take turns through one mutex and two condition variables; a sample is A's turn to B and back, same CPU and across CPUs; every turn seen in order | fast | as `mutex-handoff` | yes, as `mutex-handoff` | same act | kernel rows only; `nullcall.root-same-space` beside `ipcbench` is the nearest |
| `thread-create-join` | `pthread_create` of a thread that returns at once, then `pthread_join`; both 0 and the thread's value returned | fast | `__clone` over `erx_thread_create`, `erx_fiasco_thread_set_clear_word` and `erx_thread_start` ([design-fiasco.md](design-fiasco.md#musl-over-the-backend)), the stack an anonymous `mmap`; the join a `futex` wait on the clear word | yes, as `mutex-handoff` | same act | kernel rows only; none |
| `nanosleep` | `nanosleep` of 1 ms; a sample is the interval less 1 ms, and an interval under 1 ms is an early return, a wrong answer | expensive | `sleep_call` (`syscall.c:247-262`): a timed wait on a word nothing wakes | yes | same act; [`wake.park-deadline`](#1-wake-how-late-a-waiting-thread-runs) is the kernel table's absolute form of it | kernel rows only; none |

**Processes.**

| Operation | Act and correct result | Profile | erXos's path | erXos runs it | Same act? |
| --- | --- | --- | --- | --- | --- |
| `spawn-main` | the parent stamps and calls `posix_spawn` of the program in a mode whose first statement stamps and writes the stamp to an inherited pipe; one CPU; the child's `getpid` equals the process id `posix_spawn` returned | expensive | the planner in `liberx` and then `ENOSYS` (`liberx/program/spawn.c:44-50`); by design, the handler's request, the command server's process id, the port driver's sub-space of about 23 kernel calls, `liberx`'s start-up and the startup message ([design-programs.md](design-programs.md#the-cost-of-a-program)) | waits on `posix_spawn`'s request | same call; Linux's musl clones with `CLONE_VM` and `CLONE_VFORK` and `execve`s an ELF file of the initramfs (`musl/src/process/posix_spawn.c:152`, `:198-199`), erXos maps the program from its release |
| `spawn-wait` | `posix_spawn` of a child that exits at once and `waitpid` for it, one interval: the program itself, exiting 7, and toybox's `true`, exiting 0; `waitpid` returns the child's id and its status | expensive | as `spawn-main`; `wait4` answers `ENOSYS` (`program_task.c:328-331`), and by design reads the child table that the handler's reports fill ([design-programs.md](design-programs.md#the-posix-lite-personality)) | waits on `posix_spawn`'s request and the child table | as `spawn-main` |

L4Re, for both: kernel rows only; none. Starting a program to its exit,
end to end, is `spawn-wait` of `true`. There is no `fork` row: the first
tier has no `fork`.

**Memory.** The program-level form of [`vm`](#4-vm-what-memory-costs).
Anonymous private mappings of 1 and 64 pages, read and write.

| Operation | Act and correct result | Profile | erXos's path | erXos runs it | Same act? |
| --- | --- | --- | --- | --- | --- |
| `mmap` | `mmap`; every page reads zero | fast | the seam hands an anonymous mapping back (`program_task.c:80-81`) to musl's row, `erx_vm_reserve` and then `erx_space_protect`, which commits (`syscall.c:141-169`), each a request to the root service, as every `vm` call on Fiasco is | yes | nearest counterpart: erXos commits at `mmap`, Linux at the first touch |
| `touch` | the first write to each page of a fresh 64-page mapping, a sample a page; each reads back | fast | a plain write: the commit has mapped the pages (FD7) | yes | nearest counterpart, as `mmap` |
| `munmap` | `munmap`; afterwards `mprotect` of the range fails with `ENOMEM`, POSIX's answer for an unmapped page, so a `munmap` that did nothing fails the cell | fast | `erx_prog_fd_munmap`'s checks and `erx_vm_release` (`liberx/program/fd.c:940-959`); `mprotect` over a hole is `ENOMEM` ([design-programs.md](design-programs.md#the-posix-lite-personality)) | yes | same act |
| `map-cycle` | `mmap` of 64 pages, the first write to each, `munmap`, one interval; the checks above, untimed | fast | the three above | yes | same act: the endpoint both systems share, as `vm.commit-touch` is |

L4Re, for every memory row: kernel rows only; the kernel table's `vm`
rows have no L4Re counterpart. The `vm` cells are the parts beneath
erXos's rows: `vm.reserve`, `vm.protect` and `vm.release` from a test
task, which the program table prints beside `mmap` and `munmap` and
never subtracts from them.

**Whole workloads.** Each started by the program with `posix_spawn`,
its pipes and file actions, as a shell would start it, so no shell is
on either system's path; every command is toybox's applet of that name,
built from the tree's toybox for each system, so the commands are the
same code too.

| Operation | Act and correct result | Profile | erXos runs it |
| --- | --- | --- | --- |
| `pipeline` | three stages joined by pipes: `find` over a generated tree of 1,000 files in 50 directories, its names to `xargs grep -l KEY`, and that to `wc -l`, from the first spawn to the last `waitpid`; the count equals the generator's | expensive | waits on `posix_spawn`'s request, the child table and directory reads (`find` reads directories) |
| `untar` | toybox's `tar xf` of a generated archive of 1,000 files in 50 directories into a fresh directory of `/tmp`, then `rm -r` of it untimed; every file's bytes equal the archive's | expensive | waits on `posix_spawn`'s request, the child table, `mkdirat` and `unlinkat` |

Same act on both systems, and L4Re: kernel rows only; none. The tree and
the archive are made by one Ruby generator from a fixed seed, so every
system reads the same bytes; on erXos they are files of the image's
release, on Linux of the initramfs, each system's own read-only file
service.

**Erlang.** `erl`, in clock `counter` as `xdomain`'s modules use it, and
placement `runtime`. L4Re: none.

| Operation | Act and correct result | Profile | erXos's path | erXos runs it |
| --- | --- | --- | --- | --- |
| `spawn-down` | `spawn_monitor` of a process that returns at once, to its `'DOWN'`; reason `normal` | fast | ERTS's process creation, as stock's | yes |
| `ets-insert`, `ets-lookup` | `ets:insert` and `ets:lookup` of integer keys with 64-byte binary values in a `set` of 10,000; the value read is the value written | fast | ERTS's ETS | yes |
| `read-file` | `file:read_file` of 4 KiB and 64 KiB, the whole call; the bytes equal | fast | four requests to the server of the path's grant: an open, its size, the reads up to it and a close (`otp/erts/preloaded/src/erx_file_remote.erl:799-815`); stock OTP makes the same four calls of its kernel. It is not the read of an already open file through which `tools/erx bench fs` sets a program's handler against an Erlang process ([design-programs.md](design-programs.md#performance)) | yes, where the image's domain holds a writable `/tmp`, which for the `xdomain` bench image is unverified |
| `tcp-rtt` | 64 bytes and back over a `gen_tcp` loopback connection; the reply equals the request | fast | the domain's network service, `erx_net`, on its loopback interface | waits on an image that runs `erx_net` on its loopback interface; whether the `xdomain` bench image does is unverified |

A local message round trip is `xdomain.local-rtt`, which the Erlang
table already holds; `erl` does not time it again. Stock OTP's
counterpart of each is the same call on Linux, where `read-file` and
`tcp-rtt` reach Linux's kernel through ERTS's drivers.

### Genode's guest

Genode is the second microkernel operating system in the comparison: its
programs, as erXos's do, reach files and other programs through
components in user mode. It runs the program table's rows, and nothing
of the kernel table.

**Kernels.** Genode runs on several kernels; each is a system of its
own, `genode-hw`, `genode-sel4` and `genode-foc`, so the record never
sets two of them in one environment. Proposed: Genode's own `base-hw`
kernel, which its documentation says runs on ARM without a separate
kernel; seL4, whose 64-bit ARM support Genode's 25.11 release notes say
was added, developed on QEMU's `virt` machine and run daily on the
i.MX8Q EVK board; and Fiasco.OC, which would hold the kernel family
constant against erXos's Fiasco, if Genode supports it on 64-bit ARM.
Genode's platform page says it supports seL4 on 32-bit ARM and that
Fiasco.OC runs on many ARM platforms, without saying which Genode
supports on 64-bit ARM (References). So `base-hw` on QEMU's `virt` and
on the Raspberry Pi 4, seL4 on the Raspberry Pi 4, and Fiasco.OC
anywhere on 64-bit ARM are unverified, each until Genode's own
documentation at the pinned release says so; a kernel it does not
support there has no row.

**License and clean room.** Genode is under the GNU Affero General
Public License version 3 (References). It is a test oracle: fetched at
a pinned release and SHA-256, built out of the tree, run in a guest as a
black box, never shipped and never redistributed, as L4Re is. No agent
reads its source, directly or through another agent's record of it. Its
documentation and release notes are read, and a fact they do not state
is settled by a black-box probe in the guest, a call and the answer the
guest gives, or stays unverified.

**Build.** Genode's own build system, run as its documentation
describes, inside an offline container on the x86-64 host that runs the
remote QEMU cells; only L4Re's build uses the development host's Docker.
The container keeps the whole contract of [L4Re's guest](#l4res-guest),
not only the oracle's confinement flags (`OracleContainer::CONFINEMENT`):
it is created from a pinned image with no network, an init, private IPC
and cgroup namespaces, no capabilities or privilege gain, no engine log,
restart or health check, and no mounts; its swap is bounded by its
memory; the engine's inspection of it must show it offline, unprivileged
and unmounted before anything is copied in; its sources and tools are
copied in owned by root, so the build, as a non-root user started under
`env -i`, cannot write them; its log is bounded at 64 MiB and its output
is a bounded archive unpacked only when it holds exactly the expected
regular files, read only when printable where it is text. The build
runs on that host, as the remote cells run there, and every command
names that host's engine by its local UNIX socket, so no engine is
reached over the network. The tool chain is Genode's pre-compiled one, published
for Debian 12.10 and Ubuntu 24.04 with its SHA-256 and installed at
`/usr/local/genode/tool/<version>` with the prefix `genode-aarch64-`
(References), fetched by the fetch step and copied into the container,
never fetched by the build. `erx_peer_bench` is built as a Genode
component from a target description of erXos's (`bench/genode/`), with
Genode's C library, a VFS that gives the program `/tmp` as a file
system in memory, and the program's `posix_spawn` where Genode's C
library offers it (unverified). That Genode's C library derives from
FreeBSD's is unverified in the documents read. What comes back is the
boot image and the resolved configuration, as L4Re's build returns its
files, bounded and read only as data.

**Boot and lines.** `QemuPlan.argv` with Genode's boot image as
`-kernel`, Genode's own QEMU start is not used, so its QEMU arguments are
erXos's. Genode prints a component's log behind its label; the importer
of its boot drops the label, as L4Re's drops ned's tag, and nothing else.
Whether Genode's log carries a 64 KiB line whole is unverified; a cut
line is `rejected`, which is visible and fails safe, and if lines are
cut the program writes its lines through Genode's terminal path instead,
settled when the guest is built. The boot ends at the program's `CLOCK`
line, and QEMU is ended as at a checkpoint.

### How erXos runs the program

The `posix` image is the programs suite's test image
(`Programs.test_image`, `tools/lib/erx/programs.rb:573-599`), with one
change to its manifest and its memory. The development manifest caps a
session's `/tmp` at 2 MiB (`config/manifest/development.txt:87`), which
the two 16 MiB files of `read-seq` and `copy` and `untar`'s extraction
exceed, so the image's build (`PosixBench.manifest`) raises the
session's `tmp` limit to 48 MiB. `/tmp` is charged to the session's
budget as it is used, so the build grows by the same 48 MiB each budget
that holds it: the session's memory (`limits session`), the system
principal's memory, which admits the session, and the machine's
`root_memory`, which holds the principal's
(`config/manifest/qemu-virt-development.txt:268`, `:303`); QEMU's RAM
grows by as much (`PosixBench.machine`, 752 MiB on QEMU `virt`). A
session's runtime limits must lie within its principal's ceiling
(`dom_limits_within`, `liberx/system/dom_core.c:295-305`, called at
`:1235`), and the system principal's ceiling is the system domain's own
`runtime_limits`, so the build raises the system domain's `tmp` limit to
48 MiB too. That limit is a cap, charged only as the system domain's
own `/tmp` is used, which nothing in the image does. The edits go
through the harness's manifest edit (`Manifest::Edit`), as the `g5` and
`web` benchmarks build their images from edited manifests
(`tools/lib/erx/bench_g5.rb:222`, `bench_web.rb:145`), and the session's
Linux guest boots with the same RAM (`LinuxGuest.machine`). It is the
production image with `erx_peer_bench`, built as a program from
`NativeRoot::PROGRAM` and the file as the suite builds its programs, and
toybox's `true`, `find`, `xargs`, `grep`, `wc`, `tar` and `rm`, the
generated tree and archive in the domain release. At root's session the
console types `erx_peer_bench posix`, by its bare name, at the command
shell, as the suite types its `rc` cases (`Programs.checkpoints`), with
the environment's CPU count as its second argument; the program's
standard output is an
open on the session's terminal, so its lines reach the console as it
wrote them and the serial log is read as every guest's is. A line
reaches the serial log ending in two carriage returns and a newline,
and the reader (`NativeBench.guest_lines`) drops a newline with every
carriage return before it and nothing else. The boot ends at the program's `CLOCK` line and
QEMU is ended as at a checkpoint. The `erl` cells run in the `xdomain`
bench image, typed into its shell as `xdomain`'s module is, under that
boot's one `CLOCK` line.

### The benchmarks other designs name

[design-pipes.md](design-pipes.md#performance) names `tools/erx bench
pipe`: the latency of one byte through an idle pipe, one writer and one
reader moving 1 GiB in writes of 4 KiB and of 64 KiB, many writers under
one reader, `pipe` and spawns per second, and `poll` over 500 ends.
[design-programs.md](design-programs.md#performance) names `spawn`,
`spawn-cost`, `make` and `fs`, the last setting a program's read of an
open file beside an Erlang process's to price the handler. Those acts
are theirs and stay distinct: a one-way byte through an idle pipe is not
`pipe-rtt`'s round trip, a 1 GiB stream at two write sizes is not
`pipe-stream`'s 64 MiB at one, and none of them sets erXos beside
another system. They share the implementation, `erx_peer_bench`'s
harness and line writer, and the form of their declarations, never
cells; a number of one is never read as the other's.

### What it needs

Each is new and named here; nothing else is added.

* **`posix` in `erx_peer_bench.c`**, with an erXos build: the clock
  through `erx_fiasco_counter`, pinning through `sched_setaffinity`, the
  CPU count from its argument, the `peer` forms, and the probe of each
  call; the benchmarks that need `fork` or Linux's
  `/proc` (`nullcall`, `vm`, `wake`) are built only for Linux,
  since erXos runs its own guests for them. One file keeps one line
  writer, one calibration and one set of profiles for every system.
* **The batching rule in increments** in the C guest library
  (`erx_bench_batch_for`, `test/guest/bench/bench_hist.h:40-48`), which
  counts ticks, and the cap of 256 in the Erlang one
  (`bench/erx_bench_hist.erl:79-91`), which has none, so the two apply
  [the one rule](#the-one-clock).
* **One definition of the code-generation flags** that `PeerBench` and
  the program build both read, and the program built as an
  `FP_SOURCES` file is.
* **The `posix` image's manifest edit and memory**, above.
* **Declarations** `tools/lib/erx/benches/posix.rb` and `erl.rb`, each
  operation with its `same act` or `nearest counterpart` line and its
  per-system entries, from which the program table is printed.
* **The program table** in `Erx::BenchSideBySide`: one row per cell,
  a column per system, and the declaration's line. The kernel table is
  the one `tools/lib/erx/bench_side_by_side.rb` calls the C table, a
  name that does not tell it from the program table.
* **The images**: the `posix` image above; Linux's initramfs gains
  toybox's applets, built static against Alpine's musl by the same
  compiler, the generated tree and archive, a `/tmp` directory, and in
  `/init` the loopback interface brought up, which the network rows
  need and which the Erlang guest's `/init` already does.
* **The generator** of the tree and the archive, a Ruby function of a
  seed, whose consumer is `pipeline` and `untar`.
* **Genode's guest**: its lock (`bench/genode/deps.lock`, read only by
  `tools/erx fetch --genode`), its container build on that x86-64 host, its
  target description and its line importer.

### Their tests

| Test | Passing case | Seeded failure that must fail it |
| --- | --- | --- |
| the probe of a call | on erXos, `stat` comes back `unsupported: stat answered ENOSYS` and `read` `measured` | the probe dropped: `stat`'s timed loop counts failed calls and the cell is `failed`, never a number |
| erXos's build of the program | it links and passes `CounterReads` | the Linux branch's own counter read compiled into the erXos build: `CounterReads` refuses the program, so the erXos build is shown to take its own clock |
| `open` and `close` | the lowest-number check holds after the loop | a seeded build that skips one `close` in a hundred: the next `open` returns a higher number and the cell is `failed` |
| `munmap` | the `mprotect` afterwards answers `ENOMEM` on both systems | a seeded build whose `munmap` does nothing: `mprotect` succeeds and the cell is `failed` |
| `pipe-rtt` | every reply equals its request | the peer flipping one byte in a hundred replies: the cell is `failed` |
| `spawn-main` | the child's `getpid` equals the spawn's id | a child reporting its id plus one: the cell is `failed`; on erXos, until a program's `getpid` reads its startup record, this cell fails the same way, which is the check working |
| `nanosleep` | no early return | a seeded build sleeping 0.5 ms: every sample is early and the cell is `failed` |
| the program table | an erXos and a Linux boot of `posix` print one row per cell with both columns and the declaration's line | a declaration without its line: the declaration is refused before any boot |
| Genode's importer | a fixture erXos writes in the labelled form gives `measured` cells | the label left on: every line is `rejected` |
| the batching rule (C and Erlang, on the host) | at an increment of one tick a median of 3 ticks gives a batch of 64; at an increment of 1,000 ticks a median of 30,000 gives 4, and a median of 0 gives 256, from both libraries alike | the increment ignored in the C library: the 30,000-tick median gets a batch of 1 and a histogram of steps of 1,000 |
| the CPU count | a four-CPU erXos boot's `posix` run calibrates the pair of CPU 0 and CPU 3 and runs its cross-CPU cells | the count taken from `sysconf` instead: the run sees one CPU, calibrates no pair and reports its cross-CPU cells `unsupported`, and its `CLOCK` line, which does not calibrate the pair the boot asked, makes every cell of the boot `rejected` |

Sensitivity run, as [Verification](#verification) defines them: a
100 us busy wait in `erx_prog_handler`'s answer to a file read, which
reports its executions, must raise `posix.read`'s median by about
100 us and leave `posix.getpid`'s and `posix.mmap`'s where they were,
which shows the row went through the session's Erlang handler.

### Open decisions of the program benchmarks

* **Toybox or erXos's own commands in the workloads.** erXos's command
  shell runs Erlang commands under several of these names, which is what
  an erXos user runs. Recommendation: toybox on both, so the row is one
  act; the commands a user meets are a later row of their own.
* **The landing matrix.** Recommendation: `posix` and `erl` run in
  comparison sessions and on demand, never at the landing gate, which
  keeps its three boots; a session's numbers are the evidence a change
  to a program's paths brings.
* **Genode's kernels.** Recommendation: `base-hw` and seL4 under HVF
  first, Fiasco.OC only where Genode's documentation at the pin names
  64-bit ARM support, and the board once Genode's documentation names
  the Raspberry Pi 4.

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
slice, 1 ms, ended by a timer interrupt programmed for its end and
deferred by up to Fiasco's 200 us floor
([design-fiasco.md, Scheduling](design-fiasco.md#scheduling)), so it
lasts 1 to 1.2 ms. Task A's one thread in `share-tasks`
gets about a fifth, and its longest gap is about four turns: Fiasco
shares a level among threads, whichever task holds them, the limitation
[design-fiasco.md, Bands](design-fiasco.md#bands) records, measured and
not judged.

**What it catches.** A slice that reverts to Fiasco's 10 ms default, a
thread starved at its level, and a band that no longer protects the work
above it. Fiasco gives a thread whose quantum is 0 its default slice
(`Sched_context::set`, `src/kern/sched_context-fixed_prio.cpp:198-200`
and `:212-214`), which is `CONFIG_SCHED_DEF_TIME_SLICE` times
`CONFIG_SCHED_GRANULARITY` microseconds in either timer mode
(`src/kern/config.cpp:161-162`), by default 10 times 1,000 us
(`src/Kconfig:353-367`) under the
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
| `kernel` | the act L4Re's `syscallbench` times, so the two Fiascos are set beside each other on one act: a blocking IPC call to the calling thread's own capability, carrying a thread-control operation that Fiasco answers with an early exit and no switch; which operation, and what Fiasco answers, are read from Fiasco's source, which is MIT, when the guest is written, and named in the record | the answer Fiasco gives that call | fast |

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
it is shown, not subtracted: the two differ by the root service's
receive, decode and refusal, the request's word, the fork's patches
and the compilers, and the difference isolates none of them.

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
| `commit-touch` | `erx_vm_commit` of 64 reserved pages and the first write to each, one interval | `ERX_OK`, and the checks above | fast |
| `protect` | `erx_space_protect` of 1 and 64 committed pages to read-only and back | `ERX_OK`, and the checks above | fast |
| `map` | `erx_mem_create` of 64 pages, `erx_vm_map` of it at reserved addresses of the caller's own space, then `erx_vm_release` of the range and `erx_cap_close` of the object, each timed | `ERX_OK` throughout | expensive |
| `mem-child` | `erx_mem_child` of a 64-page object | `ERX_OK`; the record says it is an eager copy on Fiasco | expensive |

**What it catches.** A commit or a protect whose plan walks more than it
should (the watch list's 65,500 probes of the loader's window is one), a
page charged or zeroed twice, and the cost the root as pager adds over a
kernel's map. Its counterparts on Linux are anonymous
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
establish. Stock OTP on Linux runs the same module as E-D1's baseline
([Linux's Erlang guest](#linuxs-erlang-guest)).

**What it catches.** A funnel, lane or facet change that adds a copy, a
pass or a wake to a small request across domains, against the same
exchange inside one domain.

**What it needs.** An Erlang module `bench/erx_xdomain_bench.erl`; a test
image built from the `system_domain` suite's, which boots `erx_echo_test`
in one domain and grants its facet to a peer and to the system
principal's session (`tools/lib/erx/system_domain_regrant.rb`); the
client runs in a domain the facet is granted to, which this image must
give it. No new facet: the echo service is the test-only one that
exists. The module reaches its echo through one function chosen by the
boot, so the same module runs on stock OTP. The same boot runs `wake`'s `erlang-timer`
(`bench/erx_wake_bench.erl`), under the one `CLOCK` line.

The Erlang guests share `bench/erx_bench_hist.erl`, the twin of the C
guest library. Their clock is `counter`: ERTS's monotonic time in its
native unit, which on erXos is `erx_clock_ns`, the system counter scaled
to nanoseconds (`otp/erts/emulator/sys/erxos/sys_time.c`), so the line's
frequency is 1 GHz while the counter steps at its own rate. A batch
therefore spans 100 of the calibration's smallest increments, by the
rule of [the one clock](#the-one-clock) the C guests follow too. The
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
`lifecycle`'s `spawn_monitor` to `DOWN` is `erl.spawn-down` and a
program's spawn to its `main` is `posix.spawn-main`
([What a program sees](#what-a-program-sees-posix-and-erl)); it times
them from there rather than again.

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
it; it holds a console device exclusively, so a second run's open is
refused. Who reads a console's TCP port is up to the server behind it:
the Glasgow UART applet serves one connection and closes the walk's when
another opens, which ends the walk with its console closed. `pi4_http_stage.rb` takes no part in the lock and writes into
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
| a baseline with fewer than three boots, or none | the comparison is `inconclusive`, not an error |
| `--paired` without two images | refused |
| `--systems` naming a system not in `erxos`, `l4re`, `linux`, `genode-hw`, `genode-sel4`, `genode-foc`, or one with no guest in the environment | refused before any boot, naming it |
| `--systems` for a system whose pins the fetch step has not fetched | refused before any boot, naming the missing source |
| a comparison of two records whose environments differ only in their system | refused as any comparison of unequal environments is, naming the system; the side-by-side table is the only view across systems |
| a record of a guest's environment without its system | refused as a record that does not parse |
| a cell no other system has a counterpart for | not asked of that system; the side-by-side table prints `none` |
| an L4Re line the importer cannot read, or whose count is not 10,000 calls (20,000 IPCs, 10,000 syscalls), whose unit is not `cpu-cycles`, or whose mean is not its total over its count | its cell is `rejected`; a declared counterpart no line reports is `not_run` |
| an ipcbench error line for a program | that program's cell is `failed` |
| ipcbench unable to read its cycle counter | every L4Re cell `unsupported`, reporter ipcbench |
| a `mean` cell offered to a comparison | refused: `a mean has no distribution to compare` |
| an L4Re boot in a form of more than one CPU | refused before the boot: `ipcbench does not place its threads` |
| an Erlang boot whose `ERX_ORACLE` line is not 29.1.2 in the expected flavour, or is missing | refused; its cells are `rejected`, naming the version seen |
| a board import without `--subject` | the run is written with every subject field the log does not state `unknown` |
| a call that answers `ERX_ENOTSUP` | the cell is `unsupported`, reported by the backend |
| a sustained cell whose `WINDOW` lines are not exactly one for each of its windows and threads, in order | the cell is `rejected`, naming the first missing or misplaced line |
| `WINDOW` lines followed by a `BENCH` line of another profile, or by none | the lines are refused |
| a `measured` sustained cell with a thread that made no pass in a window | the cell is `failed`, naming the thread and the window |
| `--env pi4-4gb-erxos` without `--console`, `--ssh DEST` or `--key FILE` | refused before anything is built, naming what is missing |
| a console device that cannot be opened, or that another run holds; a console `tcp:HOST:PORT` that is malformed or cannot be reached | refused before anything is served |
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
| the verdict | three baseline boots and three candidates: within the band is `same`, two of three above it by more than the threshold `slower`, one of three `inconclusive` | one of three accepted as `slower` |
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
| `nullcall` | every root and task cell's run answers `ERX_EINVAL` and raises its caller's count of refusals by exactly the calls it made | the requests sent to an empty capability slot instead of the service, from the root and in a second seeded build from the task: the stub still answers `ERX_EINVAL`, the count does not move, and that caller's cells are `failed` for it |
| `vm` | each cell's untimed check passes, and the disposable task's write to its read-only page faults at that address | `erx_space_protect` made to answer `ERX_OK` without calling the service: the task's write succeeds, it exits with no fault, and the cell is `failed` |
| the GPIO probe's matching | the importer, given a capture whose third stimulus has no response before the fourth, ends the cell after the second sample, `partial`, and matches no later edge of that capture | the next response matched to the third stimulus: the cell holds a sample for it |
| the window accounting (C, on the host) | at a 24 MHz counter and a 1,000 us slice, a gap of 0.6 ms is one lost turn whose ticks are added to `waited`, a gap of 0.4 ms is a pass, and a window no read fell in is one gap of its whole length with no pass | the slice taken as ticks without the frequency: the 0.4 ms gap counts as a lost turn |
| a sustained cell | twelve `WINDOW` lines, three windows of four threads, then `share-equal`'s `BENCH` line give a `measured` cell with each thread's share and the longest gap; with one `WINDOW` line dropped the cell is `rejected`, and with a thread making no pass in window 1 it is `failed` | the line count check removed: the cell missing a line is `measured`; the idle-window check removed: the starved cell is `measured` |
| a sustained comparison | three baseline boots whose longest gaps are 4 to 6 ms and three candidates at 30 ms give `slower` | the direction reversed, as for a rate: the verdict is `faster` |
| a system's environment | an erXos and a Linux record of one model and CPU count under HVF are named `...-erxos` and `...-linux`, their comparison is refused naming the system, and the side-by-side table sets them beside each other | the system left out of the name: the two records share an environment and the comparison gives a verdict |
| Linux's guest | a one-CPU boot of the Linux guest gives `measured` cells through `BenchMeasurement`, a `CLOCK` line, and its serial log in the run directory | `erx_peer_bench` built with the seeded lost wake the native bench root takes (`-DERX_BENCH_SEED_LOST_WAKE`): `wake-same-cpu` comes back `failed` with one lost wake, which only the binary in that initramfs can have produced |
| the zboot payload, if QEMU needs it unpacked | the inflated kernel matches the pin's `decoded_sha256` and boots | the pin's decoded hash altered by one digit: the boot step refuses the kernel before QEMU starts |
| L4Re's importer | a fixture erXos writes in the facts record's format gives one `measured` `mean` cell in `cycles` per counterpart, with 10,000 calls and a round trip of the total over 10,000 | a fixture with one counterpart's line removed: that cell is `not_run`, never a number; one with a field cut short: `rejected`; one with the program's error line: `failed` |
| the ipcbench line reader | a fuzz target over the importer's line reader, with the fixtures as seeds, runs its budget clean | the count check removed: the fuzzer finds a line of count 0 that divides by zero or is accepted |
| a `mean` through the record | a `mean` cell written by `BenchRecord.write` and read back has its count, total and printed mean, no percentiles, no maximum and no event counts, and the side-by-side table shows it without a ratio | the writer summarizing every cell from its histogram: the read-back cell reports a median of 0 and zero lost wakes |
| a batched cell's total | an erXos cell of 20 samples in batches of 32 that spanned 3,000 ticks of the 24 MHz counter shows 640 operations and a mean of 195.3 ns beside its median of 4 ticks, and a total its samples rule out, such as one batch's ticks, is refused | the total shown without dividing it by its count, or the count taken as the samples instead of the operations: the mean is 3,000 ticks or 150; the range check dropped: one batch's ticks are read as the run's |
| `cycles` stays cycles | an L4Re `mean` beside an erXos cell whose boot's `CLOCK` line measured cycles per tick prints cycles and no ratio | the conversion through the other boot's calibration put back: the table prints nanoseconds for L4Re |
| Linux's Erlang guest | the bench suite's one-CPU boot gives an `ERX_ORACLE 29.1.2 jit` line and `measured` `local-rtt` and `xdomain-pingpong` cells in `monotonic`; without the install export its cell is `not_run`, never `passed` | `/init` built with `-DERX_INIT_SEED_ECHO_COOKIE`, the echo node started with another cookie: `xdomain-pingpong` is `failed`, the connection refused, while `local-rtt` is `measured`, which shows the cross cell went to the other OS process over distribution |
| L4Re's guest | a one-CPU boot of `bootstrap.elf` reaches `Benchmarks done.` and the importer reads every counterpart | an image built with `E=hello` instead of `E=ipcbench`: every L4Re cell is `not_run`, which shows the rows came from ipcbench's own output |
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
* **cyclictest, lmbench and stress-ng on Linux.** They are
  GPL and measure their own operations; one small program of erXos's own,
  on every system, compares like with like and needs no clean room.
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
* **Kernel rows alone, with a note that erXos's programs pay more.** The
  kernel table answers what erXos's kernel costs and nothing about what a
  program pays, which is mostly the session's Erlang services; a note
  cannot be compared, and the program table can.
* **A program of erXos's own for erXos and a POSIX twin for the
  others.** Two sources would let the act drift between them; one file
  makes it the same by construction, and the per-system lines stay the
  clock and the probe.
* **FreeBSD and QNX.** Later candidates for every table, on the board
  and under HVF, not in any now: FreeBSD's numbers add nothing beyond
  Linux's to the comparison yet, and QNX is the microkernel system whose
  services in user mode are closest to erXos's.
* **L4Re's POSIX layer for the program rows.** Too thin to run the
  program set; L4Re stays in the kernel table, and each program row says
  so.

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

For [the comparison under HVF](#other-systems-in-qemu-under-hvf),
fetched on 2026-11-24 into `~/erxos-scratch/src-benchvm/` over HTTPS and
read as data; nothing fetched was run. A URL that moves (a `latest` list, a page's source) names where the file came from; the SHA-256 names what was read:

| Source | File | SHA-256 |
| --- | --- | --- |
| Alpine Linux 3.24.4, aarch64 release list, `https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/latest-releases.yaml`, fetched while 3.24.4 was the latest | `alpine/latest-releases.yaml` | `196908ccecdc7e4792a727acfa127800d6a3379532a10d7ace379ba597b867db` |
| Alpine Linux 3.24.4 netboot, the `virt` kernel's configuration, `.../netboot-3.24.4/config-6.18.60-0-virt` | `alpine/config-6.18.60-0-virt` | `b7643cddcd3ba109183a2aaafa3c911d91e7d89485fd7b2caf5ede9396bf78ca` |
| Alpine Linux 3.24.4 netboot, the `virt` kernel, `.../netboot-3.24.4/vmlinuz-virt`; only its first 96 bytes were read | `alpine/vmlinuz-virt` | `cd05fed9e617b5df93dc62ece9b78c422fd94e9b432a2f7c092714b139d5eef4` |
| L4Re, "Building With GNU Make", `https://l4re.org/_sources/getting_started/make.rst` | `l4re/getting_started_make.html` | `62fda3601a52d661177ece6a94391dc6fa18fa685aaa2f91f91a9812643fc041` |
| L4Re, "MacOS", `https://l4re.org/_sources/getting_started/macosx.rst` | `l4re/getting_started_macosx.html` | `724796166e09583c594ff9066f73a9a3b340f99928ddd522456b1df1dc50e805` |
| L4Re, "Cross-Compiling", `https://l4re.org/_sources/detailed_introduction/buildsystem/cross_compiling.rst` | `l4re/detailed_introduction_buildsystem_cross_compiling.html` | `86235cc92b75c169391aa43bc3e7f4cdc053f3d5af6a3cd1f22f213ec370c116` |
| L4Re, "Using Clang", `https://l4re.org/_sources/detailed_introduction/buildsystem/clang.rst` | `l4re/clang.rst` | `9b5e1c5bb82ad84de14eb87590bc4c70cd177e346109f2599ca4b5ae4fadc9c8` |
| L4Re's manifest, `https://raw.githubusercontent.com/L4Re/manifest/main/default.xml`, MIT | `l4re/default.xml` | `3a932eb2471f0fa47c65d39ab370156e24124ec6194e441e7ca88c73c7ecb571` |
| L4Re's manifest at `5ff21e46799a4f333fb5ebc5a44d89c76474101b` ("Add tegra-soc-driver"), its last commit at or before Fiasco `07ea18e1`'s commit date, its `default.xml` read from a bare clone of `https://github.com/L4Re/manifest.git`; the same file as the row above | not kept | `3a932eb2471f0fa47c65d39ab370156e24124ec6194e441e7ca88c73c7ecb571` |
| L4Re's repositories' commits at or before Fiasco `07ea18e1`'s commit date on each default branch, from bare blobless clones of each (`mk`, `l4re-core`, `bootstrap`, `libfdt`, `drivers-frst`, `fiasco`); commit metadata only, no source read; each archive's SHA-256 is git's tar of the commit, in `bench/l4re/deps.lock` | not kept | `mk` `deaeb51e`, `l4re-core` `885283ad`, `bootstrap` `a578475b`, `libfdt` `5756062b`, `drivers-frst` `0b0d7e1c`, `fiasco` `07ea18e1` |
| L4Re's snapshot directory, `https://l4re.org/download/snapshots/` | `l4re/snapshots.html` | `50633d11cc0a0e7ffb6238826bebaa59abd0370d923504fe2d516920af63f536` |
| ipcbench's file list and last commit before 2026-10-15, GitHub's API for `l4re/ipcbench`; file names only, no source read | `ipcbench/tree.json`, `ipcbench/commits.json` | `a9bae27369188ab20035825e02fa7604c35e346ba31bb8d7dc800fa91ee8c4aa`, `e7a7c99d7d13db7b11820ef1a839952a09b196dfd99df5e0fdb6cdbcaf27fe3c` |
| ipcbench's commits up to Fiasco `07ea18e1`'s commit date, a bare blobless clone of `https://github.com/l4re/ipcbench.git`; commit metadata only, no source read | not kept | last commit `148682322103a984ddf84eb1a28e67a3d50c0b28`, `2026-09-08T09:00:00Z`; no newer commit on its default branch |
| Fiasco `07ea18e1`'s commit date, a bare blobless clone of `https://github.com/L4Re/fiasco.git`; the date is in the commit object itself, which the fetch step's pinned `git` source of upstream Fiasco holds and its build record keeps | not kept | committed `2026-11-18T13:33:24+01:00` (`2026-11-18T12:33:24Z`), "arm/32: remove old L4Linux hack" |
| Alpine Linux 3.24, the community repository's aarch64 package index, `https://dl-cdn.alpinelinux.org/alpine/v3.24/community/aarch64/APKINDEX.tar.gz`, fetched on 2026-11-24 into `~/erxos-scratch/src-benchvm-otp/`; its `erlang27` is 27.3.4.19-r0 and `erlang28` 28.5.0.8-r0, and it has no OTP 29 | `APKINDEX-community-aarch64.tar.gz`, and its `APKINDEX` | `5ec81c2e76ccd4ad5dfdc086097be0076340799cd406427b4b04ae350f141c71`, `444363bc845796ad75f3409962a011c8d276243682d6276ea207c658408e4a42` |

ipcbench's source, `https://github.com/l4re/ipcbench` at `148682322103a984ddf84eb1a28e67a3d50c0b28` ("Add missing headers when using musl"), was read only by the separate agent that wrote its facts record, `~/erxos-scratch/reports/ipcbench-facts.md` (SHA-256 `84ba07081538052073641078c6e3c04dac4c0165cfd982e1a4a3c6963718f784`), which lists the SHA-256 of each of the fifteen files it read; this document and the importer rely on that record alone.

For [Genode's guest](#genodes-guest), fetched on 2026-11-25 into
`~/erxos-scratch/genode-docs/` over HTTPS from `genode.org` and read as
data; documentation only, no source, and nothing fetched was run. The
pages carry no release of their own but the notes' numbers:

| Source | File | SHA-256 |
| --- | --- | --- |
| "Overview of the different kernels supported by Genode", `https://genode.org/documentation/platforms/index` | `platforms.html` | `618742c54445eb7709cdd1497efbbdcc4895c9d2b63d52557bc7eec35d6191f1` |
| Release notes 25.11, `https://genode.org/documentation/release-notes/25.11`: "seL4 kernel", 64-bit ARM support on QEMU's `virt` and the i.MX8Q EVK | `rn-25.11.html` | `e04012eab1bb94c3d0c95c790dc5e8e30481aabc437767816e67620b4a9ee552` |
| Release notes 25.05, `.../release-notes/25.05`: the tool chain on GCC 14.2.0 and its `install-toolchain` command | `rn-25.05.html` | `951ed637bbcf98fc0c9ba125cd7eb9f43b29a12c459ce3759747454cc0702bfe` |
| Release notes 26.08, the latest on the index, `.../release-notes/26.08` | `rn-26.08.html` | `ad22beef337d293cf8fd58ff7309c8cfabe2345ad86a13958252782e5a74e402` |
| Release notes 24.11, 25.08, 26.02 and 26.05, searched for 64-bit ARM kernels and for the Raspberry Pi 4, which none of them names | `rn-24.11.html`, `rn-25.08.html`, `rn-26.02.html`, `rn-26.05.html` | `4dae3bb7d9bcee137f6d3f5491b0705ce1983c02847814c19f68a3a1a3ba040d`, `374541cf54cf40b0d2f97c57d20986c6d7143874561039485b7cf43ab4e0ef08`, `4b7bb68a5cdccc61fbc8d4fd224253438b5bb90809468518edfea1de061fb8f2`, `8734e4a0b2c5488ec7d07fb964079fcb8de8f5ed54de712ff2de11394a167284` |
| The release-notes index, `.../release-notes/index` | `release-notes-index.html` | `2806f84d793adba46729b67bee9d8f3f7f1177c97243148f938b35e2e25fb23e` |
| "Licensing", `https://genode.org/about/licenses`: the GNU Affero General Public License version 3 | `licenses.html` | `527600fdd9a3bd85ab1759afa26e73d7d23cb097e671423870d1c4e2ec1efea7` |
| "Tool chain", `https://genode.org/download/tool-chain`: GNU tools, pre-compiled for Debian 12.10 and Ubuntu 24.04, installed at `/usr/local/genode/tool/<version>`, prefixed `genode-aarch64-` | `tool-chain.html` | `e5e177232496fcef8cdb739b0123e8cea3a9a33e5cfd7f59ac01ec60ce7c2677` |

In the tree, for [What a program sees](#what-a-program-sees-posix-and-erl):
`musl/src/internal/erxos/syscall.c`, `liberx/backend/fiasco/program_task.c`,
`liberx/program/file.h`, `file.c`, `fd.c` and `spawn.c`,
`musl/src/process/posix_spawn.c` and its `erxos` replacement,
`musl/src/stat/stat.c` and `fstatat.c`, `musl/src/unistd/getpid.c`,
`musl/arch/aarch64/syscall_arch.h`, `liberx/backend/fiasco/arch/aarch64/clock.c`,
`tools/lib/erx/counter_reads.rb` and `tools/lib/erx/programs.rb`.

In the tree: [design-fiasco.md](design-fiasco.md) (Urgency, Bands, The
trace ring, Measurements, Verification), [design-build.md](design-build.md)
(What the gates run, Reusing passing boots),
[design-domains.md](design-domains.md#performance),
[design-host-oracle.md](design-host-oracle.md),
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
