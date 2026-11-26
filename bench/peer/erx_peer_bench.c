/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_peer_bench: the POSIX counterparts of the native bench guest's cells, for the other
 * systems erXos is compared with (docs/design-bench.md, "Other systems on the same
 * Raspberry Pi 4"), and posix, what a program sees (docs/design-bench.md, "What a program
 * sees: `posix` and `erl`"), which runs on erXos too. One run times one benchmark, as one
 * boot of the native bench image does, and prints its BENCH lines (and a sustained cell's
 * WINDOW lines) and then one CLOCK line, the lines the guests print, through the guests'
 * own line library, so tools/lib/erx/bench_measurement.rb reads every system alike:
 *
 *	erx_peer_bench nullcall|vm|wake|sched|xdomain
 *	erx_peer_bench posix CPUS
 *
 * posix is given the machine's CPU count, 1 to 256, which it never asks the system for:
 * on erXos musl's sysconf answers 1 whatever the machine.
 *
 * It is the one file the other system's compiler is given; it includes the guests' line,
 * histogram, clock, sweep and window sources, which come with it from the tree's
 * test/guest/bench and liberx/backend/core/mem.h. The profiles' sizes and the xdomain
 * cells' parameters are the build's, as tools/lib/erx/peer_bench.rb derives them:
 *
 *	cc -std=c17 -O2 -pthread -I ROOT $(PeerBench.flags) ROOT/bench/peer/erx_peer_bench.c
 *
 * erXos builds it as a program with ERX_PEER_ERXOS defined (tools/lib/erx/posix_bench.rb),
 * and there it is posix alone: the others need fork or Linux's /proc.
 *
 * Every interval is ticks of one clock: the architecture's system counter where user mode
 * may read it, clock "counter", and otherwise CLOCK_MONOTONIC in nanoseconds, clock
 * "monotonic"; on erXos the counter as erx_fiasco_counter reads it, and where the build
 * defines ERX_PEER_COUNTER (Genode's) the counter without the probe, since whether such a
 * system delivers a refused read as a signal is unverified. Threads are pinned with
 * sched_setaffinity on Linux and erXos and pthread_setaffinity_np on FreeBSD, the one
 * placement call Genode's C library, built from FreeBSD's, also has; that and the
 * wake handshake, which reads B's state from Linux's /proc, are where the file differs by
 * system. The main thread of a native-set or posix
 * benchmark runs on CPU 0, the service's CPU, and the pair its CLOCK line calibrates is
 * CPU 0 and the last, as a native boot's is; an xdomain run is not pinned. A posix run
 * given "unpinned" after its CPU count pins nothing, for a system whose placement call
 * is refused (Genode's): its single-thread cells run wherever the system puts the thread,
 * every cell that times a peer thread, on the same CPU or across CPUs, is unsupported,
 * and its CLOCK line calibrates no pair.
 *
 * An operation the design's counterparts table names no counterpart for, or whose
 * counterpart the system or the machine cannot run, is reported unsupported with the
 * reason, never timed as something else. A setup failure prints a FAILED line and
 * ends the run with no CLOCK line, so the host rejects the run rather than read part of it.
 */

#if defined(__linux__) || defined(ERX_PEER_ERXOS)
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#if defined(__FreeBSD__) && !defined(ERX_PEER_ERXOS)
#include <pthread_np.h>
#endif
#include <sched.h>
#include <setjmp.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>

#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>

#if defined(ERX_PEER_ERXOS)
#include "liberx/backend/fiasco/log.h"
#elif defined(__FreeBSD__)
#include <sys/param.h>
#include <sys/cpuset.h>
#elif !defined(__linux__)
#error "erx_peer_bench pins threads on Linux, FreeBSD and erXos only"
#endif

#include "test/guest/bench/bench_hist.c"
#include "test/guest/bench/bench_clock.c"
#include "test/guest/bench/bench_periodic.c"
#include "test/guest/bench/bench_window.c"
#include "test/guest/bench/bench_line.c"

#if !defined(ERX_BENCH_FAST_WARMUP) || !defined(ERX_BENCH_FAST_SAMPLES) || !defined(ERX_BENCH_PERIODIC_SAMPLES) || \
    !defined(ERX_BENCH_SUSTAINED_SAMPLES) || !defined(ERX_BENCH_SUSTAINED_WARMUP_MS) ||                              \
    !defined(ERX_BENCH_EXPENSIVE_WARMUP) || !defined(ERX_BENCH_EXPENSIVE_SAMPLES) ||                                 \
    !defined(ERX_PEER_XDOMAIN_BYTES) || !defined(ERX_PEER_XDOMAIN_ENCODED) || !defined(ERX_PEER_RUN_DEADLINE_S)
#error "the build passes the landing profiles' sizes, the xdomain cells' parameters and the run's deadline"
#endif

#define READ_PAIRS	10000u
#define ROUNDS		1000u
#define LINE_BYTES	65536u
#define NS_PER_SECOND	UINT64_C(1000000000)
#define MS_PER_SECOND	UINT64_C(1000)
/* A park-deadline period: 1 ms. The first deadline is this many periods after the run starts. */
#define PERIODS_PER_SECOND	UINT64_C(1000)
#define PERIODIC_LEAD	10u
/* B waits this long for a wake; a wait that reaches it lost its wake. */
#define WAKE_PATIENCE_S	1
/* The protect check's child ends with this when its write faults. */
#define FAULTED		3
/* The sample the seeded lost wake's A does not wake, as the native bench root's. */
#ifdef ERX_BENCH_SEED_LOST_WAKE
#define SEED_SKIPPED	(ERX_BENCH_FAST_WARMUP + 3u)
#else
#define SEED_SKIPPED	UINT32_MAX
#endif
/* share-equal's landing cell's parameters, which tools/lib/erx/benches/sched.rb declares. */
#define SHARE_THREADS	4u
#define SHARE_WINDOW_MS	1000u
/*
 * A spinner's gap longer than half of this slice is a lost turn: the slice erXos's root
 * configures, since POSIX schedulers configure none, so a lost turn means the same on
 * every system.
 */
#define SHARE_SLICE_US	UINT64_C(1000)
/*
 * The size of posix's pattern file, and the part every sequential read and write and every
 * pipe-stream write moves; also the largest round trip but xdomain's.
 */
#define PART_BYTES	65536u
#define TRIP_BYTES_MAX	(PART_BYTES > ERX_PEER_XDOMAIN_BYTES ? PART_BYTES : ERX_PEER_XDOMAIN_BYTES)
#define NO_COUNTERPART	"no counterpart named in the design"
#define ONE_CPU		"the machine has one CPU"
#define UNPINNED	"threads are not pinned on this system"
#define WAKE_UNREADABLE	"B's blocked state is not readable on this system"
#define WRONG_RESULT	"wrong result"
#define MOST_SAMPLES_2(a, b)	((a) > (b) ? (a) : (b))
#define MOST_SAMPLES	\
	MOST_SAMPLES_2(MOST_SAMPLES_2(ERX_BENCH_FAST_SAMPLES, ERX_BENCH_PERIODIC_SAMPLES), ERX_BENCH_EXPENSIVE_SAMPLES)

/* The run's clock: its name as the lines give it, its frequency and its read. */
static const char *clock_name;
static uint64_t clock_hz;
static uint64_t (*clock_read)(void);

static unsigned cpus;
/* Set by a posix run given "unpinned": no thread is pinned and no cell with a peer runs. */
static bool unpinned;
static const char *benchmark;
static size_t page_bytes;

static char line[LINE_BYTES];
/* Each cell's histogram, which a line carries. */
static erx_bench_hist_t hist;
/* The fast runs' warm-up and the read calibration's deltas, never a cell's. */
static erx_bench_hist_t scratch;
static erx_bench_reads_t read_pairs[READ_PAIRS];
static erx_bench_token_t token;
static erx_bench_round_t rounds[ROUNDS];
static uint64_t samples[MOST_SAMPLES];

/* Ends the run with a FAILED line naming what failed: a setup failure, which prints no cell. */
static _Noreturn void
peer_fail(const char *what)
{
	printf("erx: bench: %s FAILED\n", what);
	fflush(stdout);
	exit(1);
}

static void
peer_say(const char *text)
{
	fputs(text, stdout);
	fflush(stdout);
}

static void
peer_print_line(size_t length)
{
	if (length == 0 || length >= sizeof(line) - 1)
		peer_fail("a line did not fit");
	line[length] = '\n';
	if (fwrite(line, 1, length + 1, stdout) != length + 1 || fflush(stdout) != 0)
		peer_fail("a line was not written");
}

/* The clocks. */

#if defined(ERX_PEER_ERXOS)
/*
 * erXos's program reads the counter through erx_fiasco_counter, the one read of it a linked
 * program may make, and does not probe: a program on Fiasco catches no signal.
 */
static void
clock_choose(void)
{
	clock_name = "counter";
	clock_hz = erx_fiasco_counter_hz();
	clock_read = erx_fiasco_counter;
}
#else
static uint64_t
monotonic_ns(void)
{
	struct timespec now;

	if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
		peer_fail("CLOCK_MONOTONIC did not read");
	return ((uint64_t)now.tv_sec * NS_PER_SECOND + (uint64_t)now.tv_nsec);
}

#if defined(__aarch64__)
/* The virtual counter, as erx_fiasco_counter reads it, and its frequency register. */
static uint64_t
counter_ticks(void)
{
	uint64_t ticks;

	__asm__ volatile("isb\n\tmrs %0, cntvct_el0\n\tisb" : "=r"(ticks) : : "memory");
	return (ticks);
}

static uint64_t
counter_frequency(void)
{
	uint64_t frequency;

	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(frequency));
	return (frequency);
}

#if !defined(ERX_PEER_COUNTER)
static sigjmp_buf counter_trap;

static void
counter_trapped(int signal)
{
	(void)signal;
	siglongjmp(counter_trap, 1);
}

/* Whether user mode may read the counter: a read the system refuses traps as SIGILL. */
static bool
counter_readable(uint64_t *frequency)
{
	struct sigaction trap, old;
	volatile bool readable = false;

	memset(&trap, 0, sizeof(trap));
	trap.sa_handler = counter_trapped;
	sigemptyset(&trap.sa_mask);
	if (sigaction(SIGILL, &trap, &old) != 0)
		peer_fail("SIGILL could not be caught");
	if (sigsetjmp(counter_trap, 1) == 0) {
		*frequency = counter_frequency();
		(void)counter_ticks();
		readable = true;
	}
	if (sigaction(SIGILL, &old, NULL) != 0)
		peer_fail("SIGILL could not be restored");
	return (readable && *frequency != 0);
}
#endif
#endif

static void
clock_choose(void)
{
#if defined(__aarch64__) && defined(ERX_PEER_COUNTER)
	clock_name = "counter";
	clock_hz = counter_frequency();
	clock_read = counter_ticks;
	if (clock_hz == 0)
		peer_fail("the counter's frequency reads 0");
#else
#if defined(__aarch64__)
	uint64_t frequency = 0;

	if (counter_readable(&frequency)) {
		clock_name = "counter";
		clock_hz = frequency;
		clock_read = counter_ticks;
		return;
	}
#endif
	clock_name = "monotonic";
	clock_hz = NS_PER_SECOND;
	clock_read = monotonic_ns;
#endif
}
#endif

/*
 * The probe (docs/design-bench.md, "What a program sees: `posix` and `erl`"): the call
 * that last failed and its error, which a cell's untimed first run reads to tell a call the
 * system does not offer from a wrong answer.
 */
static struct {
	const char *call;
	int error;
} refusal;

/* Whether a call answering -1 and errno on failure succeeded; a failure is kept for the probe. */
static bool
posix_ok(const char *call, long answer)
{
	if (answer != -1)
		return (true);
	refusal.call = call;
	refusal.error = errno;
	return (false);
}

/* Whether a call answering an error number, as pthread's do, succeeded; a failure is kept for the probe. */
static bool
pthread_ok(const char *call, int error)
{
	if (error == 0)
		return (true);
	refusal.call = call;
	refusal.error = error;
	return (false);
}

/* Pinning. */

static void
pin_to(unsigned cpu)
{
	if (unpinned)
		return;
#if defined(__linux__) || defined(ERX_PEER_ERXOS)
	cpu_set_t set;

	CPU_ZERO(&set);
	CPU_SET(cpu, &set);
	if (sched_setaffinity(0, sizeof(set), &set) != 0)
		peer_fail("a thread could not be pinned");
#else
	cpuset_t set;

	CPU_ZERO(&set);
	CPU_SET(cpu, &set);
	if (pthread_setaffinity_np(pthread_self(), sizeof(set), &set) != 0)
		peer_fail("a thread could not be pinned");
#endif
}

typedef struct {
	unsigned cpu;
	bool pinned;
	void (*entry)(uint64_t);
	uint64_t index;
} peer_start_t;

static void *
peer_thread_main(void *argument)
{
	const peer_start_t start = *(const peer_start_t *)argument;

	free(argument);
	if (start.pinned)
		pin_to(start.cpu);
	start.entry(start.index);
	return (NULL);
}

/* Starts entry(index) on a new thread, pinned to cpu where pinned is set; a refusal is kept for the probe. */
static bool
thread_try_start(pthread_t *thread, unsigned cpu, bool pinned, void (*entry)(uint64_t), uint64_t index)
{
	peer_start_t *const start = malloc(sizeof(*start));

	if (start == NULL)
		peer_fail("no memory for a thread");
	*start = (peer_start_t){ .cpu = cpu, .pinned = pinned, .entry = entry, .index = index };
	if (pthread_ok("pthread_create", pthread_create(thread, NULL, peer_thread_main, start)))
		return (true);
	free(start);
	return (false);
}

static pthread_t
thread_start(unsigned cpu, bool pinned, void (*entry)(uint64_t), uint64_t index)
{
	pthread_t thread;

	if (!thread_try_start(&thread, cpu, pinned, entry, index))
		peer_fail("no thread");
	return (thread);
}

static pthread_t
peer_thread_start(unsigned cpu, void (*entry)(uint64_t), uint64_t index)
{
	return (thread_start(cpu, true, entry, index));
}

static void
peer_thread_join(pthread_t thread)
{
	if (pthread_join(thread, NULL) != 0)
		peer_fail("a thread could not be joined");
}

/* Cells and the CLOCK line. */

static erx_bench_cell_t
peer_cell(const char *operation, const char *placement)
{
	return ((erx_bench_cell_t){ .benchmark = benchmark, .operation = operation, .load = "idle",
	    .placement = placement, .clock = clock_name, .batch = 1, .frequency_hz = clock_hz, .status = "measured" });
}

static void
peer_print(erx_bench_cell_t cell, const uint64_t *values, size_t n)
{
	erx_bench_sample_t top[ERX_BENCH_LARGEST];

	erx_bench_cell_summarize(&cell, &hist, values, n, top);
	peer_print_line(erx_bench_line_cell(line, sizeof(line), &cell));
}

static void
peer_print_unsupported(const char *operation, const char *placement, const char *reason)
{
	erx_bench_cell_t cell = peer_cell(operation, placement);

	cell.status = "unsupported";
	cell.reason = reason;
	peer_print(cell, NULL, 0);
}

static void
calibrate_b(uint64_t index)
{
	(void)index;
	erx_bench_rounds_b(&token, clock_read, ROUNDS);
}

/* One calibration of the main thread's CPU, 0, against the last, whose side is a new thread. */
static erx_bench_offset_t
calibrate(void)
{
	const pthread_t b = peer_thread_start(cpus - 1, calibrate_b, 0);
	erx_bench_offset_t offset;

	erx_bench_rounds_a(&token, clock_read, rounds, ROUNDS);
	peer_thread_join(b);
	offset = erx_bench_offset(rounds, ROUNDS, erx_bench_read_calibration(read_pairs, READ_PAIRS, &scratch).increment);
	return (offset);
}

static void
print_clock(const erx_bench_pair_t *pair, size_t npairs)
{
	const erx_bench_read_cal_t reads = erx_bench_read_calibration(read_pairs, READ_PAIRS, &scratch);
	/* A timed wait takes its deadline in nanoseconds, so it rounds to one. */
	const erx_bench_calibration_t clock = { .clock = clock_name, .frequency_hz = clock_hz,
	    .increment = reads.increment, .read_cost = reads.read_cost,
	    .wait_rounding = (clock_hz + NS_PER_SECOND - 1) / NS_PER_SECOND, .cycles_per_tick_milli = 0,
	    .pairs = pair, .npairs = npairs };

	peer_print_line(erx_bench_line_clock(line, sizeof(line), &clock));
}

/*
 * A one-way cell stamped across CPU 0 and the last under the cross-CPU rule
 * (docs/design-bench.md, "The one clock"): the pair is calibrated before and after sample()
 * fills samples, each sample is corrected by the hull's middle and the hull's half-width
 * is the cell's uncertainty, or the cell is unsupported with the rule's reason. A cell
 * sample() marks failed or unsupported keeps its status, reason and counts, and no
 * samples. Answers the pair for the CLOCK line.
 */
static erx_bench_pair_t
across_cell(erx_bench_cell_t cell, size_t (*sample)(erx_bench_cell_t *cell))
{
	erx_bench_pair_t pair = { .cpus = { 0, cpus - 1 } };
	erx_bench_sample_t top[ERX_BENCH_LARGEST];
	erx_bench_offset_t hull;
	const char *unsupported;
	size_t taken;
	int64_t middle;

	pair.before = calibrate();
	taken = sample(&cell);
	pair.after = calibrate();
	if (strcmp(cell.status, "measured") != 0) {
		peer_print(cell, samples, 0);
		return (pair);
	}
	hull = erx_bench_offset_hull(pair.before, pair.after);
	middle = hull.empty ? 0 : hull.low + (hull.high - hull.low) / 2;
	for (size_t at = 0; at < taken; at++) {
		/* A corrected sample below zero lies within the uncertainty the cell states. */
		const int64_t corrected = (int64_t)samples[at] - middle;

		samples[at] = corrected < 0 ? 0 : (uint64_t)corrected;
	}
	/* The bound is a tenth of the corrected median, as the host holds it. */
	erx_bench_cell_summarize(&cell, &hist, samples, taken, top);
	unsupported = erx_bench_cell_unsupported(true, pair.before, pair.after, erx_bench_hist_median(&hist));
	if (unsupported != NULL) {
		cell.status = "unsupported";
		cell.reason = unsupported;
		peer_print(cell, samples, 0);
		return (pair);
	}
	cell.has_uncertainty = true;
	cell.uncertainty = erx_bench_offset_half_width(hull);
	peer_print(cell, samples, taken);
	return (pair);
}

/*
 * A cell's run (docs/design-bench.md, "Short operations" and "Profiles"). Its operation's
 * steps each answer whether they gave the right result: a batch is prepared untimed, its
 * operations timed back to back and undone untimed. Every run starts with the probe, the
 * operation made once untimed; then a fast run times ERX_BENCH_FAST_WARMUP batches of one
 * and ERX_BENCH_FAST_SAMPLES batches of the size the warm-up's median asks, a sample a
 * batch's mean, and an expensive run ERX_BENCH_EXPENSIVE_WARMUP operations and then
 * ERX_BENCH_EXPENSIVE_SAMPLES, each timed alone. A run's reason is NULL exactly when it
 * measured.
 */
typedef struct {
	bool (*prepare)(uint64_t at);
	bool (*act)(uint64_t at);
	bool (*undo)(uint64_t at);
} peer_op_t;

typedef struct {
	uint64_t batch;
	size_t taken;
	const char *status;
	const char *reason;
} peer_run_t;

static bool
nothing(uint64_t at)
{
	(void)at;
	return (true);
}

static bool
batch_run(const peer_op_t *op, uint64_t n, uint64_t *ticks)
{
	uint64_t start;
	bool right = true;

	for (uint64_t at = 0; at < n && right; at++)
		right = op->prepare(at);
	start = clock_read();
	for (uint64_t at = 0; at < n && right; at++)
		right = op->act(at);
	*ticks = clock_read() - start;
	for (uint64_t at = 0; at < n && right; at++)
		right = op->undo(at);
	return (right);
}

/* A run its probe ended: unsupported where the last refusal was ENOSYS or ENOTSUP, naming the call; else failed. */
static peer_run_t
probe_refused(void)
{
	static char reason[80];
	const bool lacking = refusal.call != NULL && (refusal.error == ENOSYS || refusal.error == ENOTSUP);

	if (!lacking)
		return ((peer_run_t){ .batch = 1, .taken = 0, .status = "failed", .reason = WRONG_RESULT });
	snprintf(reason, sizeof(reason), "%s answered %s", refusal.call, refusal.error == ENOSYS ? "ENOSYS" : "ENOTSUP");
	return ((peer_run_t){ .batch = 1, .taken = 0, .status = "unsupported", .reason = reason });
}

static peer_run_t
probe(const peer_op_t *op)
{
	refusal.call = NULL;
#if !defined(ERX_PEER_SEED_NO_PROBE)
	{
		uint64_t ticks;

		if (!batch_run(op, 1, &ticks))
			return (probe_refused());
	}
#else
	/* The seeded fault: no probe, so a call the system lacks fails the timed loop instead. */
	(void)op;
#endif
	return ((peer_run_t){ .batch = 1, .taken = 0, .status = "measured", .reason = NULL });
}

static peer_run_t
run_wrong(peer_run_t run)
{
	run.status = "failed";
	run.reason = WRONG_RESULT;
	return (run);
}

static peer_run_t
fast_run(const peer_op_t *op)
{
	peer_run_t run = probe(op);
	uint64_t ticks;

	if (run.reason != NULL)
		return (run);
	for (size_t at = 0; at < ERX_BENCH_HIST_BUCKETS; at++)
		scratch.count[at] = 0;
	scratch.samples = 0;
	for (uint32_t warm = 0; warm < ERX_BENCH_FAST_WARMUP; warm++) {
		if (!batch_run(op, 1, &ticks))
			return (run_wrong(run));
		erx_bench_hist_add(&scratch, ticks);
	}
	run.batch = erx_bench_batch_for(erx_bench_hist_median(&scratch));
	for (; run.taken < ERX_BENCH_FAST_SAMPLES; run.taken++) {
		if (!batch_run(op, run.batch, &ticks))
			return (run_wrong(run));
		samples[run.taken] = ticks / run.batch;
	}
	return (run);
}

static peer_run_t
expensive_run(const peer_op_t *op)
{
	peer_run_t run = probe(op);
	uint64_t ticks;

	if (run.reason != NULL)
		return (run);
	for (uint32_t warm = 0; warm < ERX_BENCH_EXPENSIVE_WARMUP; warm++)
		if (!batch_run(op, 1, &ticks))
			return (run_wrong(run));
	for (; run.taken < ERX_BENCH_EXPENSIVE_SAMPLES; run.taken++) {
		if (!batch_run(op, 1, &ticks))
			return (run_wrong(run));
		samples[run.taken] = ticks;
	}
	return (run);
}

/* Prints cell as run left it, failed when its untimed check is false; an expensive cell carries its raw samples. */
static void
run_print(erx_bench_cell_t cell, peer_run_t run, bool (*check)(void))
{
	cell.batch = run.batch;
	cell.status = run.status;
	cell.reason = run.reason;
	if (run.reason == NULL && check != NULL && !check()) {
		cell.status = "failed";
		cell.reason = "the untimed check failed";
	}
	cell.nraw = cell.raw != NULL ? run.taken : 0;
	peer_print(cell, samples, run.taken);
}

/* Byte streams between two sides: a pipe pair, or a socket pair, and an echo at the far end. */

static bool
read_full(int fd, void *buf, size_t size)
{
	uint8_t *at = buf;

	while (size > 0) {
		const ssize_t got = read(fd, at, size);

		if (got < 0 && errno == EINTR)
			continue;
		if (got <= 0)
			return (false);
		at += got;
		size -= (size_t)got;
	}
	return (true);
}

static bool
write_full(int fd, const void *buf, size_t size)
{
	const uint8_t *at = buf;

	while (size > 0) {
		const ssize_t put = write(fd, at, size);

		if (put < 0 && errno == EINTR)
			continue;
		if (put <= 0)
			return (false);
		at += put;
		size -= (size_t)put;
	}
	return (true);
}

/*
 * The near end of a round trip: where the request goes and the reply comes from, the
 * request, and whether each side polls for POLLIN before it reads (posix's poll-rtt).
 */
static int trip_out = -1, trip_in = -1;
static size_t trip_bytes;
static bool trip_polled;
static uint64_t trip_sequence;
static uint8_t trip_request[TRIP_BYTES_MAX];
static uint8_t trip_reply[TRIP_BYTES_MAX];
static uint8_t echo_message[TRIP_BYTES_MAX];

/* poll for POLLIN on fd: poll's answer, -1 with its errno, or 0 when it reported anything but POLLIN. */
static int
poll_in(int fd)
{
	struct pollfd ready = { .fd = fd, .events = POLLIN, .revents = 0 };
	const int answer = poll(&ready, 1, -1);

	return (answer == 1 && (ready.revents & POLLIN) == 0 ? 0 : answer);
}

/* Echoes messages of size bytes from in to out until in ends. */
static void
echo(int in, int out, size_t size)
{
#if defined(ERX_PEER_SEED_FLIPPED_REPLY)
	uint64_t echoed = 0;
#endif

	while ((!trip_polled || poll_in(in) == 1) && read_full(in, echo_message, size)) {
#if defined(ERX_PEER_SEED_FLIPPED_REPLY)
		/* The seeded fault: one reply in a hundred has a byte flipped. */
		if (++echoed % 100 == 0)
			echo_message[size - 1] ^= 1;
#endif
		if (!write_full(out, echo_message, size))
			return;
	}
}

/* One round trip: the request out, the reply in, equal to the request, whose first bytes carry its number. */
static bool
round_trip(uint64_t at)
{
	const uint64_t sequence = trip_sequence++;
	int polled = 1;

	(void)at;
	memcpy(trip_request, &sequence, trip_bytes < sizeof(sequence) ? trip_bytes : sizeof(sequence));
	if (!write_full(trip_out, trip_request, trip_bytes))
		return (false);
	if (trip_polled && !posix_ok("poll", polled = poll_in(trip_in)))
		return (false);
	return (polled == 1 && read_full(trip_in, trip_reply, trip_bytes) &&
	    memcmp(trip_reply, trip_request, trip_bytes) == 0);
}

/* An echo thread's ends: it echoes from echo_in to echo_out until echo_in ends. */
static int echo_in = -1, echo_out = -1;

static void
echo_thread(uint64_t index)
{
	(void)index;
	echo(echo_in, echo_out, trip_bytes);
}

/* Pages: each written page holds a seed at its start and its complement at its end. */

static uint8_t *vm_pages[ERX_BENCH_BATCH_MAX];

static void
page_fill(uint8_t *page, uint64_t seed)
{
	const uint64_t last = ~seed;

	memcpy(page, &seed, sizeof(seed));
	memcpy(page + page_bytes - sizeof(last), &last, sizeof(last));
}

static bool
page_holds(const uint8_t *page, uint64_t seed)
{
	uint64_t first, last;

	memcpy(&first, page, sizeof(first));
	memcpy(&last, page + page_bytes - sizeof(last), sizeof(last));
	return (first == seed && last == ~seed);
}

/* A page never written reads zero where page_fill writes. */
static bool
page_blank(const uint8_t *page)
{
	uint64_t first, last;

	memcpy(&first, page, sizeof(first));
	memcpy(&last, page + page_bytes - sizeof(last), sizeof(last));
	return (first == 0 && last == 0);
}

#if !defined(ERX_PEER_ERXOS)
/*
 * A native-set benchmark's cells between its two calibrations of CPU 0 against the last,
 * and its CLOCK line: with no pair on one CPU.
 */
static void
calibrated(void (*cells)(void))
{
	erx_bench_pair_t pair = { .cpus = { 0, cpus - 1 } };

	pin_to(0);
	if (cpus == 1) {
		cells();
		print_clock(NULL, 0);
		return;
	}
	pair.before = calibrate();
	cells();
	pair.after = calibrate();
	print_clock(&pair, 1);
}

/* Times op and prints its cell: failed with a wrong result, or when its untimed check is false. */
static void
fast_cell(const char *operation, const char *placement, const erx_bench_param_t *params, size_t nparams,
    const peer_op_t *op, bool (*check)(void))
{
	erx_bench_cell_t cell = peer_cell(operation, placement);

	cell.params = params;
	cell.nparams = nparams;
	run_print(cell, fast_run(op), check);
}

/*
 * Forks an echo process reading in and writing out, pinned to cpu where pinned is set; it
 * closes the near end, near, so its read ends when the near side's does.
 */
static pid_t
echo_process(int in, int out, int near, unsigned cpu, bool pinned)
{
	const pid_t child = fork();

	if (child < 0)
		peer_fail("no echo process");
	if (child == 0) {
		close(near);
		if (pinned)
			pin_to(cpu);
		echo(in, out, trip_bytes);
		_exit(0);
	}
	return (child);
}

/* Ends the near side's streams and reaps the echo process, which must end with 0. */
static void
echo_reap(pid_t child)
{
	int status;

	close(trip_out);
	close(trip_in);
	trip_out = trip_in = -1;
	while (waitpid(child, &status, 0) < 0)
		if (errno != EINTR)
			peer_fail("the echo process could not be reaped");
	if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
		peer_fail("the echo process did not end with 0");
}

/*
 * nullcall: getppid for kernel, and an 8-byte round trip over a pair of pipes from CPU 0
 * to an echo on the cell's CPU: an echo thread of this process for root-same-space, an
 * echo process for root-cross-space.
 */

static pid_t parent_pid;

static bool
ppid_call(uint64_t at)
{
	(void)at;
	return (getppid() == parent_pid);
}

/* Opens the request pipe there and the reply pipe back, and the 8-byte request. */
static void
pipes_open(int there[2], int back[2])
{
	if (pipe(there) != 0 || pipe(back) != 0)
		peer_fail("no pipe");
	trip_bytes = 8;
	memset(trip_request, 0xa5, trip_bytes);
}

static const peer_op_t pipe_trip = { nothing, round_trip, nothing };

/* root-same-space: to an echo thread on echo_cpu, which ends when there[1] closes. */
static void
pipe_thread_cell(const char *placement, unsigned echo_cpu)
{
	int there[2], back[2];
	pthread_t thread;

	pipes_open(there, back);
	echo_in = there[0];
	echo_out = back[1];
	thread = peer_thread_start(echo_cpu, echo_thread, 0);
	trip_out = there[1];
	trip_in = back[0];
	fast_cell("root-same-space", placement, NULL, 0, &pipe_trip, NULL);
	close(there[1]);
	peer_thread_join(thread);
	close(there[0]);
	close(back[0]);
	close(back[1]);
	trip_out = trip_in = echo_in = echo_out = -1;
}

/* root-cross-space: to an echo process on echo_cpu. */
static void
pipe_process_cell(const char *placement, unsigned echo_cpu)
{
	int there[2], back[2];
	pid_t child;

	pipes_open(there, back);
	/* The echo holds back[0] too, which it never reads; there[1]'s close alone ends it. */
	child = echo_process(there[0], back[1], there[1], echo_cpu, true);
	close(there[0]);
	close(back[1]);
	trip_out = there[1];
	trip_in = back[0];
	fast_cell("root-cross-space", placement, NULL, 0, &pipe_trip, NULL);
	echo_reap(child);
}

static void
nullcall_cells(void)
{
	static const peer_op_t kernel = { nothing, ppid_call, nothing };

	parent_pid = getppid();
	pipe_thread_cell("service-cpu", 0);
	if (cpus > 1)
		pipe_thread_cell("other-cpu", cpus - 1);
	else
		peer_print_unsupported("root-same-space", "other-cpu", ONE_CPU);
	pipe_process_cell("service-cpu", 0);
	if (cpus > 1)
		pipe_process_cell("other-cpu", cpus - 1);
	else
		peer_print_unsupported("root-cross-space", "other-cpu", ONE_CPU);
	fast_cell("kernel", "same-cpu", NULL, 0, &kernel, NULL);
}

/*
 * vm: one page per operation, over an area of ERX_BENCH_BATCH_MAX pages, each its own
 * anonymous mapping: commit maps it, touch writes it first, protect makes it read-only,
 * decommit frees its memory with madvise. Each cell's untimed check is the native one's
 * where POSIX can make it.
 */


static bool
page_zero(const uint8_t *page)
{
	for (size_t at = 0; at < page_bytes; at++)
		if (page[at] != 0)
			return (false);
	return (true);
}

static bool
map_one(uint64_t at)
{
	void *const page = mmap(NULL, page_bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);

	vm_pages[at] = page == MAP_FAILED ? NULL : page;
	return (vm_pages[at] != NULL);
}

static bool
unmap_one(uint64_t at)
{
	const bool unmapped = munmap(vm_pages[at], page_bytes) == 0;

	vm_pages[at] = NULL;
	return (unmapped);
}

static bool
touch_one(uint64_t at)
{
	page_fill(vm_pages[at], at);
	return (true);
}

static bool
map_touched(uint64_t at)
{
	return (map_one(at) && touch_one(at));
}

static bool
protect_one(uint64_t at)
{
	return (mprotect(vm_pages[at], page_bytes, PROT_READ) == 0);
}

#if defined(__linux__)
static bool
decommit_one(uint64_t at)
{
	return (madvise(vm_pages[at], page_bytes, MADV_DONTNEED) == 0);
}
#endif

/* The committed page reads zero. */
static bool
commit_check(void)
{
	const bool right = map_one(0) && page_zero(vm_pages[0]);

	return (unmap_one(0) && right);
}

/* The first write reads back. */
static bool
touch_check(void)
{
	const bool right = map_touched(0) && page_holds(vm_pages[0], 0);

	return (unmap_one(0) && right);
}

static void
fault_exit(int signal)
{
	(void)signal;
	_exit(FAULTED);
}

/* A write to page, which must fault: the child that makes it ends with FAULTED from its handler. */
static bool
write_faults(uint8_t *page)
{
	const pid_t child = fork();
	int status;

	if (child < 0)
		peer_fail("no process for the protect check");
	if (child == 0) {
		struct sigaction fault;

		memset(&fault, 0, sizeof(fault));
		fault.sa_handler = fault_exit;
		sigemptyset(&fault.sa_mask);
		if (sigaction(SIGSEGV, &fault, NULL) != 0 || sigaction(SIGBUS, &fault, NULL) != 0)
			_exit(1);
		page_fill(page, 1);
		_exit(0);
	}
	while (waitpid(child, &status, 0) < 0)
		if (errno != EINTR)
			peer_fail("the protect check's process could not be reaped");
	return (WIFEXITED(status) && WEXITSTATUS(status) == FAULTED);
}

/* A written page reads back after read-only and back, and a write to a read-only page faults. */
static bool
protect_check(void)
{
	bool right = map_touched(0) && protect_one(0) && page_holds(vm_pages[0], 0) && write_faults(vm_pages[0]) &&
	    mprotect(vm_pages[0], page_bytes, PROT_READ | PROT_WRITE) == 0 && page_holds(vm_pages[0], 0);

	return (unmap_one(0) && right);
}

#if defined(__linux__)
/* The decommitted page reads zero: Linux's MADV_DONTNEED zero-fills a private anonymous page. */
static bool
decommit_check(void)
{
	const bool right = map_touched(0) && decommit_one(0) && page_zero(vm_pages[0]);

	return (unmap_one(0) && right);
}
#endif

static void
vm_cells(void)
{
	static const peer_op_t commit = { nothing, map_one, unmap_one };
	static const peer_op_t touch = { map_one, touch_one, unmap_one };
	static const peer_op_t protect = { map_touched, protect_one, unmap_one };

	peer_print_unsupported("reserve", "service-cpu", NO_COUNTERPART);
	fast_cell("commit", "service-cpu", NULL, 0, &commit, commit_check);
	fast_cell("touch", "service-cpu", NULL, 0, &touch, touch_check);
	fast_cell("protect", "service-cpu", NULL, 0, &protect, protect_check);
#if defined(__linux__)
	{
		static const peer_op_t decommit = { map_touched, decommit_one, unmap_one };

		fast_cell("decommit", "service-cpu", NULL, 0, &decommit, decommit_check);
	}
#else
	/* FreeBSD's MADV_FREE frees a page lazily and leaves its contents undefined. */
	peer_print_unsupported("decommit", "service-cpu", "no madvise here frees a page to zero");
#endif
	peer_print_unsupported("release", "service-cpu", NO_COUNTERPART);
}

/*
 * wake: park-deadline is clock_nanosleep to an absolute CLOCK_MONOTONIC deadline on the
 * sweep's deadlines, on CPU 0; wake-cross-cpu is a thread B on the last CPU blocked on a
 * condition variable, which A on CPU 0 signals once B is waiting, B stamping its return:
 * one sample is B's return stamp less A's stamp before the signal, a one-way interval
 * across the calibrated pair.
 */
/* The CLOCK_MONOTONIC time at which the run's clock reads deadline, rounded up. */
static struct timespec
monotonic_at(uint64_t deadline)
{
	const uint64_t now = clock_read(), base = monotonic_ns();
	const uint64_t ahead = deadline > now ? deadline - now : 0;
	uint64_t ns;
	struct timespec at;

	/* Every deadline is at most PERIODIC_LEAD + 1 periods ahead, so the product fits. */
	ns = base + (ahead * NS_PER_SECOND + clock_hz - 1) / clock_hz;
	at.tv_sec = (time_t)(ns / NS_PER_SECOND);
	at.tv_nsec = (long)(ns % NS_PER_SECOND);
	return (at);
}


static erx_bench_stamp_t stamps[ERX_BENCH_PERIODIC_SAMPLES];
static erx_bench_periodic_t periodic;

static void
park_deadline(void)
{
	const uint64_t period = clock_hz / PERIODS_PER_SECOND, first = clock_read() + PERIODIC_LEAD * period;
	erx_bench_cell_t cell = peer_cell("park-deadline", "service-cpu");
	erx_bench_sample_t top[ERX_BENCH_LARGEST];
	size_t on_time = 0;
	uint32_t k = 0;
	size_t taken = 0;
	bool refused = false;

	while (taken < ERX_BENCH_PERIODIC_SAMPLES && !refused) {
		const struct timespec at = monotonic_at(erx_bench_periodic_deadline(first, period, k));
		int answer;

		while ((answer = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &at, NULL)) == EINTR)
			continue;
		refused = answer != 0;
		if (refused)
			break;
		stamps[taken] = (erx_bench_stamp_t){ .k = k, .returned = clock_read() };
		k = erx_bench_periodic_next(first, period, k, stamps[taken].returned);
		taken++;
	}
	erx_bench_periodic_classify(first, period, stamps, taken, &periodic);
	for (size_t at = 0; at < taken; at++) {
		const uint64_t deadline = erx_bench_periodic_deadline(first, period, stamps[at].k);

		if (stamps[at].returned >= deadline)
			samples[on_time++] = stamps[at].returned - deadline;
	}
	erx_bench_cell_summarize(&cell, &hist, samples, on_time, top);
	cell.hist = &periodic.late;
	cell.early = periodic.early;
	cell.missed = periodic.missed;
	cell.periodic = &periodic;
	if (refused) {
		cell.status = "failed";
		cell.reason = "clock_nanosleep refused a deadline";
	} else if (periodic.early != 0) {
		cell.status = "failed";
		cell.reason = "early return";
	}
	peer_print_line(erx_bench_line_cell(line, sizeof(line), &cell));
}

#if defined(__linux__)
/*
 * The wake handshake (docs/design-bench.md, the counterparts' C table). Thread B waits for
 * the sequence word to reach each sample's number in pthread_cond_timedwait, its absolute
 * deadline WAKE_PATIENCE_S away on CLOCK_MONOTONIC. Thread A takes the mutex once B has
 * released it into that wait, reads B's state in /proc/self/task/<tid>/stat until it is
 * S, stamps, sets the word, signals, releases the mutex and blocks reading the answer
 * pipe; B stamps its return and writes the stamp, or that its wait timed out, to the
 * pipe. B returning with the word changed is the wake, and ETIMEDOUT a lost wake. FreeBSD
 * shows no thread's state there, so its way to see B blocked is settled with its board
 * package, and until then its wake cells are unsupported (wake_cells).
 */
static struct {
	pthread_mutex_t lock;
	pthread_cond_t poke;	/* B waits on it, on CLOCK_MONOTONIC, for word */
	pthread_cond_t ready;	/* A waits on it for waiting */
	uint32_t waiting;	/* the sample B waits for */
	uint32_t word;		/* the sample A woke B for */
	pid_t b_task;		/* B's thread, as /proc names it */
	int answer[2];		/* the pipe B answers A on */
} shake = { .lock = PTHREAD_MUTEX_INITIALIZER };

/* What B writes A after each sample: its stamp, and whether its wait timed out. */
typedef struct {
	uint64_t stamp;
	bool lost;
} wake_answer_t;

static void
shake_lock(void)
{
	if (pthread_mutex_lock(&shake.lock) != 0)
		peer_fail("the handshake's lock was refused");
}

/* B's side of sample number: publish it, wait for the word, stamp the return. */
static wake_answer_t
b_sample(uint32_t number)
{
	struct timespec patience;
	uint64_t stamp;
	int waited = 0;

	if (clock_gettime(CLOCK_MONOTONIC, &patience) != 0)
		peer_fail("CLOCK_MONOTONIC did not read");
	patience.tv_sec += WAKE_PATIENCE_S;
	shake_lock();
	shake.waiting = number;
	pthread_cond_signal(&shake.ready);
	while (shake.word != number && waited == 0)
		waited = pthread_cond_timedwait(&shake.poke, &shake.lock, &patience);
	stamp = clock_read();
	pthread_mutex_unlock(&shake.lock);
	if (waited != 0 && waited != ETIMEDOUT)
		peer_fail("pthread_cond_timedwait refused its wait");
	/* ETIMEDOUT is a lost wake whatever the word reads by then, as the native park's is. */
	return ((wake_answer_t){ .stamp = stamp, .lost = waited == ETIMEDOUT });
}

/* B: each sample, answered to A; a lost wake ends B's samples. */
static void
wake_b(uint64_t total)
{
	shake_lock();
	shake.b_task = gettid();
	pthread_mutex_unlock(&shake.lock);
	for (uint32_t number = 1; number <= total; number++) {
		const wake_answer_t answer = b_sample(number);

		if (!write_full(shake.answer[1], &answer, sizeof(answer)))
			peer_fail("B's answer was not written");
		if (answer.lost)
			return;
	}
}

/* The state letter of thread task, the field after its command's closing parenthesis. */
static char
task_state(pid_t task)
{
	char path[64], text[512];
	const char *command_end;
	ssize_t got;
	int fd;

	snprintf(path, sizeof(path), "/proc/self/task/%ld/stat", (long)task);
	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		peer_fail("B's /proc stat did not open");
	got = read(fd, text, sizeof(text) - 1);
	close(fd);
	if (got <= 0)
		peer_fail("B's /proc stat did not read");
	text[got] = '\0';
	/* The command may hold any byte; the fields after it are numbers. */
	command_end = strrchr(text, ')');
	if (command_end == NULL || command_end[1] != ' ' || command_end[2] == '\0')
		peer_fail("B's /proc stat did not parse");
	return (command_end[2]);
}

/*
 * A's side of sample number: once B waits for it and shows asleep, stamp and, if wake is
 * set, set the word and signal. A holds the lock B gives up only inside its wait, and
 * after giving it up the C library's wait sleeps only in the kernel (musl's
 * pthread_cond_timedwait.c), so S is B asleep there. Answers A's stamp.
 */
static uint64_t
a_sample(uint32_t number, bool wake)
{
	uint64_t poked;

	shake_lock();
	while (shake.waiting != number)
		pthread_cond_wait(&shake.ready, &shake.lock);
	for (const uint64_t patience = clock_read() + clock_hz * WAKE_PATIENCE_S; task_state(shake.b_task) != 'S';) {
		if (clock_read() > patience)
			peer_fail("B never showed asleep in its wait");
		sched_yield();
	}
	poked = clock_read();
	if (wake) {
		shake.word = number;
		pthread_cond_signal(&shake.poke);
	}
	pthread_mutex_unlock(&shake.lock);
	return (poked);
}

/*
 * A: each sample, waking B unless the sample is skip, and B's stamp less A's from the
 * answer pipe. Answers the samples taken after the warm-up, and sets *lost when B's wait
 * timed out.
 */
static size_t
wake_a(uint32_t total, uint32_t skip, uint64_t *raw, bool *lost)
{
	size_t taken = 0;

	*lost = false;
	for (uint32_t number = 1; number <= total; number++) {
		const uint64_t poked = a_sample(number, number != skip);
		wake_answer_t answer;

		if (!read_full(shake.answer[0], &answer, sizeof(answer)))
			peer_fail("B's answer was not read");
		if (answer.lost) {
			*lost = true;
			break;
		}
		if (number > ERX_BENCH_FAST_WARMUP)
			raw[taken++] = answer.stamp - poked;
	}
	return (taken);
}

/* One cell's handshakes with B on b_cpu and A on CPU 0, into samples. */
static size_t
wake_samples(unsigned b_cpu, uint32_t skip, bool *lost)
{
	const uint32_t total = ERX_BENCH_FAST_WARMUP + ERX_BENCH_FAST_SAMPLES;
	pthread_t b;
	size_t taken;

	shake.waiting = shake.word = 0;
	if (pipe(shake.answer) != 0)
		peer_fail("no pipe");
	b = peer_thread_start(b_cpu, wake_b, total);
	taken = wake_a(total, skip, samples, lost);
	peer_thread_join(b);
	close(shake.answer[0]);
	close(shake.answer[1]);
	return (taken);
}

static void
handshake_init(void)
{
	pthread_condattr_t monotonic;

	if (pthread_condattr_init(&monotonic) != 0 || pthread_condattr_setclock(&monotonic, CLOCK_MONOTONIC) != 0 ||
	    pthread_cond_init(&shake.poke, &monotonic) != 0 || pthread_cond_init(&shake.ready, NULL) != 0)
		peer_fail("no condition variable");
	pthread_condattr_destroy(&monotonic);
}

/* wake-same-cpu: A and B both on CPU 0, so one counter stamps both and needs no calibration. */
static void
wake_same_cpu(void)
{
	erx_bench_cell_t cell = peer_cell("wake-same-cpu", "same-cpu");
	bool lost;
	const size_t taken = wake_samples(0, SEED_SKIPPED, &lost);

	if (lost) {
		/* The samples before the lost wake stand: no calibration needs vouching for. */
		cell.status = "failed";
		cell.reason = "lost wake";
		cell.lost = 1;
	}
	peer_print(cell, samples, taken);
}

/* wake-cross-cpu's samples, for across_cell: a lost wake fails the cell. */
static size_t
wake_cross_samples(erx_bench_cell_t *cell)
{
	bool lost;
	const size_t taken = wake_samples(cpus - 1, UINT32_MAX, &lost);

	if (lost) {
		cell->status = "failed";
		cell->reason = "lost wake";
		cell->lost = 1;
	}
	return (taken);
}

#endif

/*
 * The cells after park-deadline, and the CLOCK line. Where B's state cannot be read, the
 * wake cells are unsupported and the pair is still calibrated, so park-deadline imports.
 */
static void
wake_cells(void)
{
	erx_bench_pair_t pair = { .cpus = { 0, cpus - 1 } };

#if defined(__linux__)
	handshake_init();
	wake_same_cpu();
#else
	peer_print_unsupported("wake-same-cpu", "same-cpu", WAKE_UNREADABLE);
#endif
	peer_print_unsupported("trigger-take", "same-cpu", NO_COUNTERPART);
	if (cpus == 1) {
		peer_print_unsupported("wake-cross-cpu", "cross-cpu", ONE_CPU);
		print_clock(NULL, 0);
		return;
	}
#if defined(__linux__)
	pair = across_cell(peer_cell("wake-cross-cpu", "cross-cpu"), wake_cross_samples);
#else
	pair.before = calibrate();
	peer_print_unsupported("wake-cross-cpu", "cross-cpu", WAKE_UNREADABLE);
	pair.after = calibrate();
#endif
	print_clock(&pair, 1);
}

static void
wake_run(void)
{
	pin_to(0);
	park_deadline();
	wake_cells();
}

/*
 * sched: share-equal's spinners, SHARE_THREADS threads pinned to the last CPU at the
 * default priority, each reading the clock in a loop through the warm-up and the windows,
 * which test/guest/bench/bench_window.c keeps as the native spinners' are. The main thread,
 * on CPU 0, joins them and only then prints the WINDOW lines and the cell, so no line is
 * written while a window runs.
 */

static struct {
	uint64_t start;
	uint64_t first;
	uint64_t window;
} share;
static erx_bench_window_t share_windows[SHARE_THREADS][ERX_BENCH_SUSTAINED_SAMPLES];

static void
share_spinner(uint64_t index)
{
	const uint64_t lost_after = erx_bench_window_lost_after(clock_hz, SHARE_SLICE_US);
	uint64_t last = share.start;

	/* The warm-up keeps only its last read before the first window, so a late start is window 0's gap. */
	for (uint64_t now = clock_read(); now < share.first; now = clock_read())
		last = now;
	for (uint32_t window = 0; window < ERX_BENCH_SUSTAINED_SAMPLES; window++) {
		const uint64_t end = share.first + (uint64_t)(window + 1) * share.window;
		erx_bench_window_t kept = last < end ? (erx_bench_window_t){ 0, 0, 0, 0 } :
		    erx_bench_window_empty(share.window, lost_after);

		while (last < end) {
			const uint64_t now = clock_read();

			erx_bench_window_read(&kept, end - share.window, end, last, now, lost_after);
			last = now;
		}
		share_windows[index][window] = kept;
	}
}

static void
share_equal(void)
{
	static const erx_bench_param_t params[] = { { "threads", NULL, SHARE_THREADS },
		{ "window-ms", NULL, SHARE_WINDOW_MS } };
	erx_bench_cell_t cell = peer_cell("share-equal", "other-cpu");
	pthread_t spinners[SHARE_THREADS];

	cell.params = params;
	cell.nparams = sizeof(params) / sizeof(params[0]);
	cell.sustained = true;
	if (cpus == 1) {
		cell.status = "unsupported";
		cell.reason = ONE_CPU;
		peer_print_line(erx_bench_line_cell(line, sizeof(line), &cell));
		return;
	}
	share.start = clock_read();
	share.first = share.start + clock_hz * ERX_BENCH_SUSTAINED_WARMUP_MS / MS_PER_SECOND;
	share.window = clock_hz * SHARE_WINDOW_MS / MS_PER_SECOND;
	for (uint32_t spinner = 0; spinner < SHARE_THREADS; spinner++)
		spinners[spinner] = peer_thread_start(cpus - 1, share_spinner, spinner);
	for (uint32_t spinner = 0; spinner < SHARE_THREADS; spinner++)
		peer_thread_join(spinners[spinner]);
	for (uint32_t window = 0; window < ERX_BENCH_SUSTAINED_SAMPLES; window++)
		for (uint32_t spinner = 0; spinner < SHARE_THREADS; spinner++)
			peer_print_line(erx_bench_line_window(line, sizeof(line), window, spinner,
			    &share_windows[spinner][window]));
	cell.windows = ERX_BENCH_SUSTAINED_SAMPLES;
	peer_print_line(erx_bench_line_cell(line, sizeof(line), &cell));
}

/*
 * xdomain: a round trip of ERX_PEER_XDOMAIN_BYTES over a UNIX-domain socket pair, to an
 * echo thread of the same process for local-rtt and to an echo process for
 * xdomain-pingpong; neither side is pinned, as a runtime's processes are not. Its CLOCK
 * line calibrates no pair, as an xdomain boot's does not.
 */

static void
xdomain_run(void)
{
	static const erx_bench_param_t params[] = { { "bytes", NULL, ERX_PEER_XDOMAIN_BYTES },
		{ "encoded", NULL, ERX_PEER_XDOMAIN_ENCODED } };
	static const peer_op_t op = { nothing, round_trip, nothing };
	const size_t nparams = sizeof(params) / sizeof(params[0]);
	int ends[2];
	pthread_t thread;
	pid_t child;

	trip_bytes = ERX_PEER_XDOMAIN_BYTES;
	memset(trip_request, 0xa5, trip_bytes);

	if (socketpair(AF_UNIX, SOCK_STREAM, 0, ends) != 0)
		peer_fail("no socket pair");
	echo_in = echo_out = ends[1];
	thread = thread_start(0, false, echo_thread, 0);
	trip_out = trip_in = ends[0];
	fast_cell("local-rtt", "runtime", params, nparams, &op, NULL);
	/* The echo thread's read ends when its peer's end closes. */
	shutdown(ends[0], SHUT_RDWR);
	peer_thread_join(thread);
	close(ends[0]);
	close(ends[1]);

	if (socketpair(AF_UNIX, SOCK_STREAM, 0, ends) != 0)
		peer_fail("no socket pair");
	child = echo_process(ends[1], ends[1], ends[0], 0, false);
	close(ends[1]);
	trip_out = ends[0];
	trip_in = dup(ends[0]);
	if (trip_in < 0)
		peer_fail("no descriptor");
	fast_cell("xdomain-pingpong", "runtime", params, nparams, &op, NULL);
	echo_reap(child);
	print_clock(NULL, 0);
}
#endif

/*
 * posix: what a program sees (docs/design-bench.md, "What a program sees: `posix` and
 * `erl`"). Ordinary POSIX calls and UNIX IPC, the same file on erXos, as a program of
 * root's session, and on the other systems, in the cells tools/lib/erx/benches/posix.rb
 * declares, with the parameters it gives them. The main thread runs on CPU 0; a cell's
 * second thread runs on CPU 0 for same-cpu and on the last CPU for cross-cpu, which on one
 * CPU is unsupported. Each cell's untimed set-up and its calls' first run are its probe:
 * a call answering ENOSYS or ENOTSUP makes it unsupported, naming the call. Its files are
 * in /tmp, each made untimed by the cell that reads it, and removed untimed at the end.
 */

#define POSIX_FILE	"/tmp/erx_peer_bench.file"
#define POSIX_BIG	"/tmp/erx_peer_bench.big"
#define POSIX_COPY	"/tmp/erx_peer_bench.copy"
/* mutex-handoff: A holds the lock this long after B says it is about to lock it. */
#define HANDOFF_WAITS_PER_SECOND	UINT64_C(10000)

/* The pattern every file and stream is made of; and the buffers reads land in. */
static uint8_t pattern[PART_BYTES];
static uint8_t part[PART_BYTES];
static uint8_t part_back[PART_BYTES];

/*
 * One cell: its name, conditions and parameters as the declaration gives them, its
 * profile, whether it times a peer thread beside the main one (whose placement means
 * something only where both are pinned), its operation, and its untimed set-up, end and
 * check after the loop, each optional. The numeric parameters reach the acts through
 * posix (posix_load).
 */
typedef struct {
	const char *operation;
	const char *placement;
	const erx_bench_param_t *params;
	size_t nparams;
	bool expensive;
	bool peer;
	peer_op_t op;
	bool (*begin)(void);
	void (*end)(void);
	bool (*check)(void);
} posix_cell_t;

/* The running cell's state, set afresh for each cell. */
static struct {
	uint64_t bytes;		/* the bytes parameter */
	uint64_t pages;		/* the pages parameter */
	uint64_t ns;		/* the ns parameter: the sleep asked, which each sample is less */
	unsigned peer_cpu;	/* the second thread's CPU */
	int fd;			/* the cell's open file, or -1 */
	int lowest;		/* the lowest free descriptor, which open answers first */
	int fds[ERX_BENCH_BATCH_MAX];
	pid_t pid;
	uint64_t last_ns;	/* clock-gettime's last answer */
	int there[2];		/* the pipe A writes to the peer */
	int back[2];		/* the pipe the peer answers on */
	pthread_t peer;
	bool peer_started;
} posix;

static void
posix_load(const posix_cell_t *cell)
{
	posix.bytes = posix.pages = posix.ns = posix.last_ns = 0;
	posix.peer_cpu = strcmp(cell->placement, "cross-cpu") == 0 ? cpus - 1 : 0;
	posix.fd = posix.lowest = -1;
	posix.there[0] = posix.there[1] = posix.back[0] = posix.back[1] = -1;
	posix.peer_started = false;
	for (size_t at = 0; at < cell->nparams; at++) {
		const erx_bench_param_t *const param = &cell->params[at];

		if (param->text != NULL)
			continue;
		if (strcmp(param->name, "bytes") == 0)
			posix.bytes = param->count;
		else if (strcmp(param->name, "pages") == 0)
			posix.pages = param->count;
		else if (strcmp(param->name, "ns") == 0)
			posix.ns = param->count;
		else
			peer_fail("a posix cell has a parameter no act reads");
	}
}

/* Whether a read or write answered exactly want bytes; a refusal is kept for the probe. */
static bool
posix_full(const char *call, ssize_t answer, uint64_t want)
{
	return (posix_ok(call, (long)answer) && (uint64_t)answer == want);
}

static void
descriptor_drop(int *fd)
{
	if (*fd >= 0)
		close(*fd);
	*fd = -1;
}

/* Trivial calls. */

static bool
getpid_begin(void)
{
	posix.pid = getpid();
	return (posix.pid > 0);
}

static bool
getpid_same(uint64_t at)
{
	(void)at;
	return (getpid() == posix.pid);
}

static bool
clock_forward(uint64_t at)
{
	struct timespec now;
	uint64_t ns;

	(void)at;
	if (!posix_ok("clock_gettime", clock_gettime(CLOCK_MONOTONIC, &now)))
		return (false);
	ns = (uint64_t)now.tv_sec * NS_PER_SECOND + (uint64_t)now.tv_nsec;
	if (ns < posix.last_ns)
		return (false);
	posix.last_ns = ns;
	return (true);
}

/* Files. */

/* Writes path afresh: bytes of the pattern, in parts. */
static bool
file_make(const char *path, uint64_t bytes)
{
	const int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	bool made = posix_ok("open", fd);

	for (uint64_t offset = 0; made && offset < bytes; offset += PART_BYTES)
		made = posix_full("write", write(fd, pattern, PART_BYTES), PART_BYTES);
	if (fd >= 0)
		made = posix_ok("close", close(fd)) && made;
	return (made);
}

static bool
file_open(const char *path, int flags)
{
	posix.fd = open(path, flags, 0644);
	return (posix_ok("open", posix.fd));
}

static void
file_end(void)
{
	descriptor_drop(&posix.fd);
}

static bool
made_begin(void)
{
	return (file_make(POSIX_FILE, PART_BYTES));
}

static bool
read_begin(void)
{
	return (made_begin() && file_open(POSIX_FILE, O_RDONLY));
}

static bool
write_begin(void)
{
	return (made_begin() && file_open(POSIX_FILE, O_RDWR));
}

/* open's and close's: the lowest free descriptor, which every open of the loop starts from. */
static bool
lowest_begin(void)
{
	if (!read_begin())
		return (false);
	posix.lowest = posix.fd;
	file_end();
	return (true);
}

/* The open of a batch's at'th operation: the lowest free descriptor, at above the batch's first. */
static bool
open_lowest(uint64_t at)
{
	posix.fds[at] = open(POSIX_FILE, O_RDONLY);
	return (posix_ok("open", posix.fds[at]) && posix.fds[at] == posix.lowest + (int)at);
}

static bool
close_opened(uint64_t at)
{
#if defined(ERX_PEER_SEED_LEAKED_CLOSE)
	/* The seeded fault: one close in a hundred is skipped, so a later open answers higher. */
	static uint64_t closes;

	if (++closes % 100 == 0)
		return (true);
#endif
	return (posix_ok("close", close(posix.fds[at])));
}

/* After the loop one more open still answers the lowest, so no close left a descriptor behind. */
static bool
lowest_check(void)
{
	const int fd = open(POSIX_FILE, O_RDONLY);
	const bool lowest = fd == posix.lowest;

	if (fd >= 0)
		close(fd);
	return (lowest);
}

static bool
stat_right(const struct stat *st)
{
	return (st->st_size == (off_t)PART_BYTES && S_ISREG(st->st_mode));
}

static bool
fstat_file(uint64_t at)
{
	struct stat st;

	(void)at;
	return (posix_ok("fstat", fstat(posix.fd, &st)) && stat_right(&st));
}

static bool
stat_path(uint64_t at)
{
	struct stat st;

	(void)at;
	return (posix_ok("stat", stat(POSIX_FILE, &st)) && stat_right(&st));
}

static bool
pread_first(uint64_t at)
{
	(void)at;
	return (posix_full("pread", pread(posix.fd, part, posix.bytes, 0), posix.bytes));
}

static bool
pwrite_first(uint64_t at)
{
	(void)at;
	return (posix_full("pwrite", pwrite(posix.fd, pattern, posix.bytes, 0), posix.bytes));
}

/* The bytes the last pread read are the pattern. */
static bool
read_check(void)
{
	return (memcmp(part, pattern, posix.bytes) == 0);
}

/* The bytes written read back. */
static bool
write_check(void)
{
	return (pread(posix.fd, part, posix.bytes, 0) == (ssize_t)posix.bytes && read_check());
}

static bool
big_read_begin(void)
{
	return (file_make(POSIX_BIG, posix.bytes) && file_open(POSIX_BIG, O_RDONLY));
}

static bool
big_write_begin(void)
{
	return (file_open(POSIX_BIG, O_WRONLY | O_CREAT | O_TRUNC));
}

static bool
copy_begin(void)
{
	return (file_make(POSIX_BIG, posix.bytes));
}

static bool
read_through(uint64_t at)
{
	bool right = true;

	(void)at;
	for (uint64_t offset = 0; right && offset < posix.bytes; offset += PART_BYTES)
		right = posix_full("pread", pread(posix.fd, part, PART_BYTES, (off_t)offset), PART_BYTES);
	return (right);
}

static bool
write_through(uint64_t at)
{
	bool right = true;

	(void)at;
	for (uint64_t offset = 0; right && offset < posix.bytes; offset += PART_BYTES)
		right = posix_full("pwrite", pwrite(posix.fd, pattern, PART_BYTES, (off_t)offset), PART_BYTES);
	return (right);
}

/* The big file copied in parts to a truncated second file, both opened and closed. */
static bool
copy_through(uint64_t at)
{
	const int from = open(POSIX_BIG, O_RDONLY), to = open(POSIX_COPY, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	bool right = posix_ok("open", from) && posix_ok("open", to);

	(void)at;
	for (uint64_t offset = 0; right && offset < posix.bytes; offset += PART_BYTES)
		right = posix_full("read", read(from, part, PART_BYTES), PART_BYTES) &&
		    posix_full("write", write(to, part, PART_BYTES), PART_BYTES);
	if (from >= 0)
		right = posix_ok("close", close(from)) && right;
	if (to >= 0)
		right = posix_ok("close", close(to)) && right;
	return (right);
}

/* The copy reads back equal, and no longer. */
static bool
copy_check(void)
{
	const int from = open(POSIX_BIG, O_RDONLY), to = open(POSIX_COPY, O_RDONLY);
	bool equal = from >= 0 && to >= 0;

	for (uint64_t offset = 0; equal && offset < posix.bytes; offset += PART_BYTES)
		equal = pread(from, part, PART_BYTES, (off_t)offset) == PART_BYTES &&
		    pread(to, part_back, PART_BYTES, (off_t)offset) == PART_BYTES && memcmp(part, part_back, PART_BYTES) == 0;
	equal = equal && pread(to, part_back, 1, (off_t)posix.bytes) == 0;
	if (from >= 0)
		close(from);
	if (to >= 0)
		close(to);
	return (equal);
}

/* UNIX IPC: two pipes between A, the main thread, and its peer, a second thread. */

/* Opens the pipes and starts the peer, entry, reading echo_in and answering on echo_out. */
static bool
pipes_peer(void (*entry)(uint64_t))
{
	if (!posix_ok("pipe", pipe(posix.there)) || !posix_ok("pipe", pipe(posix.back)))
		return (false);
	echo_in = posix.there[0];
	echo_out = posix.back[1];
	trip_out = posix.there[1];
	trip_in = posix.back[0];
	posix.peer_started = thread_try_start(&posix.peer, posix.peer_cpu, true, entry, 0);
	return (posix.peer_started);
}

/* Closes A's end of the request pipe, which ends the peer's reads, joins it and closes the rest. */
static void
pipes_end(void)
{
	descriptor_drop(&posix.there[1]);
	if (posix.peer_started)
		peer_thread_join(posix.peer);
	descriptor_drop(&posix.there[0]);
	descriptor_drop(&posix.back[0]);
	descriptor_drop(&posix.back[1]);
	trip_out = trip_in = echo_in = echo_out = -1;
	trip_polled = false;
}

static bool
rtt_begin(void)
{
	if (posix.bytes > sizeof(trip_request))
		peer_fail("a round trip is larger than its buffer");
	trip_bytes = (size_t)posix.bytes;
	memcpy(trip_request, pattern, trip_bytes);
	return (pipes_peer(echo_thread));
}

static bool
poll_begin(void)
{
	trip_polled = true;
	return (rtt_begin());
}

/* pipe-stream: A's parts, each the pattern led by its number, and B's count and checksum. */
static struct {
	uint8_t out[PART_BYTES];
	uint8_t in[PART_BYTES];
	uint64_t sum;			/* the checksum of the stream A writes */
	_Atomic uint64_t got;		/* the bytes B read of its last stream */
	_Atomic uint64_t got_sum;	/* their checksum */
} stream;

/* The checksum of a stream so far, sum, and its next part: order matters, so a part out of place shows. */
static uint64_t
stream_add(uint64_t sum, const uint8_t *next)
{
	uint64_t word, words = 0;

	for (size_t at = 0; at < PART_BYTES; at += sizeof(word)) {
		memcpy(&word, next + at, sizeof(word));
		words += word;
	}
	return (((sum << 1) | (sum >> 63)) + words);
}

/* B: reads each stream to its end, keeps its count and checksum, and answers one byte. */
static void
stream_reader(uint64_t index)
{
	const uint8_t answer = 1;

	(void)index;
	for (;;) {
		uint64_t got = 0, sum = 0;

		for (; got < posix.bytes; got += PART_BYTES) {
			if (!read_full(echo_in, stream.in, PART_BYTES))
				return;
			sum = stream_add(sum, stream.in);
		}
		atomic_store(&stream.got, got);
		atomic_store(&stream.got_sum, sum);
		if (!write_full(echo_out, &answer, sizeof(answer)))
			return;
	}
}

static bool
stream_begin(void)
{
	stream.sum = 0;
	memcpy(stream.out, pattern, PART_BYTES);
	for (uint64_t number = 0; number < posix.bytes / PART_BYTES; number++) {
		memcpy(stream.out, &number, sizeof(number));
		stream.sum = stream_add(stream.sum, stream.out);
	}
	atomic_store(&stream.got, 0);
	atomic_store(&stream.got_sum, 0);
	return (pipes_peer(stream_reader));
}

/* A: the stream in parts, then B's answer; B's count and checksum equal A's. */
static bool
stream_one(uint64_t at)
{
	uint8_t answer;

	(void)at;
	for (uint64_t number = 0; number < posix.bytes / PART_BYTES; number++) {
		memcpy(stream.out, &number, sizeof(number));
		if (!write_full(trip_out, stream.out, PART_BYTES))
			return (false);
	}
	return (read_full(trip_in, &answer, sizeof(answer)) && answer == 1 && atomic_load(&stream.got) == posix.bytes &&
	    atomic_load(&stream.got_sum) == stream.sum);
}

/* Threads and time. */

/* cond-pingpong: A and B take turns through one mutex and two condition variables. */
static struct {
	pthread_mutex_t lock;
	pthread_cond_t to_b;
	pthread_cond_t to_a;
	uint64_t turn;	/* odd while B's turn is due, even once B has taken it */
	bool stop;
	bool wrong;	/* B saw a turn out of order */
} pingpong = { .lock = PTHREAD_MUTEX_INITIALIZER, .to_b = PTHREAD_COND_INITIALIZER,
	.to_a = PTHREAD_COND_INITIALIZER };

static void
pingpong_b(uint64_t index)
{
	uint64_t next = 1;

	(void)index;
	pthread_mutex_lock(&pingpong.lock);
	for (;;) {
		while (pingpong.turn % 2 == 0 && !pingpong.stop)
			pthread_cond_wait(&pingpong.to_b, &pingpong.lock);
		if (pingpong.stop)
			break;
		if (pingpong.turn != next)
			pingpong.wrong = true;
		next = pingpong.turn + 2;
		pingpong.turn++;
		pthread_cond_signal(&pingpong.to_a);
	}
	pthread_mutex_unlock(&pingpong.lock);
}

static bool
pingpong_begin(void)
{
	pingpong.turn = 0;
	pingpong.stop = pingpong.wrong = false;
	posix.peer_started = thread_try_start(&posix.peer, posix.peer_cpu, true, pingpong_b, 0);
	return (posix.peer_started);
}

static void
pingpong_end(void)
{
	pthread_mutex_lock(&pingpong.lock);
	pingpong.stop = true;
	pthread_cond_broadcast(&pingpong.to_b);
	pthread_mutex_unlock(&pingpong.lock);
	if (posix.peer_started)
		peer_thread_join(posix.peer);
}

/* One sample: A's turn to B and back, every turn seen in order. */
static bool
pingpong_turn(uint64_t at)
{
	uint64_t mine;
	bool right;

	(void)at;
	if (!pthread_ok("pthread_mutex_lock", pthread_mutex_lock(&pingpong.lock)))
		return (false);
	mine = ++pingpong.turn;
	pthread_cond_signal(&pingpong.to_b);
	while (pingpong.turn == mine)
		pthread_cond_wait(&pingpong.to_a, &pingpong.lock);
	right = pingpong.turn == mine + 1 && !pingpong.wrong;
	pthread_mutex_unlock(&pingpong.lock);
	return (right);
}

static void *
thread_returns(void *argument)
{
	return (argument);
}

static bool
create_join(uint64_t at)
{
	pthread_t thread;
	void *value = NULL;

	(void)at;
	return (pthread_ok("pthread_create", pthread_create(&thread, NULL, thread_returns, &posix)) &&
	    pthread_ok("pthread_join", pthread_join(thread, &value)) && value == &posix);
}

static bool
sleep_once(uint64_t at)
{
#if defined(ERX_PEER_SEED_SHORT_SLEEP)
	/* The seeded fault: half the sleep asked, so every sample is an early return. */
	const uint64_t ns = posix.ns / 2;
#else
	const uint64_t ns = posix.ns;
#endif
	const struct timespec asked = { .tv_sec = (time_t)(ns / NS_PER_SECOND), .tv_nsec = (long)(ns % NS_PER_SECOND) };

	(void)at;
	return (posix_ok("nanosleep", nanosleep(&asked, NULL)));
}

/*
 * A sleep's samples: each interval less the sleep asked, in whole ticks rounded down, so
 * an interval under it is surely an early return, a wrong answer, which is counted and
 * not kept.
 */
static void
sleep_less(erx_bench_cell_t *cell, peer_run_t *run)
{
	const uint64_t asked = posix.ns * clock_hz / NS_PER_SECOND;
	size_t kept = 0;

	for (size_t at = 0; at < run->taken; at++)
		if (samples[at] >= asked)
			samples[kept++] = samples[at] - asked;
	cell->early = run->taken - kept;
	run->taken = kept;
	if (cell->early != 0) {
		run->status = "failed";
		run->reason = "early return";
	}
}

/*
 * mutex-handoff, under the cross-CPU rule: B, on the last CPU, says it is about to lock the
 * mutex A holds; A waits 100 us, stamps and unlocks; B stamps when its lock returns. A
 * sample is B's stamp less A's.
 */
static struct {
	pthread_mutex_t lock;
	_Atomic uint32_t go;	/* the sample A asks B for */
	_Atomic uint32_t about;	/* the sample B is about to lock for */
	_Atomic uint32_t done;	/* the sample B has stamped */
	uint32_t handed;	/* the sample A unlocked for, written under the lock */
	uint64_t stamp;		/* B's stamp, which done publishes */
	_Atomic bool wrong;	/* B did not get the lock A unlocked */
} handoff = { .lock = PTHREAD_MUTEX_INITIALIZER };

static void
handoff_b(uint64_t total)
{
	for (uint32_t number = 1; number <= total; number++) {
		bool locked;

		while (atomic_load(&handoff.go) != number)
			continue;
		atomic_store(&handoff.about, number);
		locked = pthread_mutex_lock(&handoff.lock) == 0;
		handoff.stamp = clock_read();
		if (!locked || handoff.handed != number)
			atomic_store(&handoff.wrong, true);
		if (locked)
			pthread_mutex_unlock(&handoff.lock);
		atomic_store(&handoff.done, number);
	}
}

static uint64_t
handoff_sample(uint32_t number, uint64_t wait)
{
	uint64_t unlocked;

	if (pthread_mutex_lock(&handoff.lock) != 0)
		peer_fail("the handoff's mutex was refused");
	handoff.handed = number;
	atomic_store(&handoff.go, number);
	while (atomic_load(&handoff.about) != number)
		continue;
	for (const uint64_t until = clock_read() + wait; clock_read() < until;)
		continue;
	unlocked = clock_read();
	pthread_mutex_unlock(&handoff.lock);
	while (atomic_load(&handoff.done) != number)
		continue;
	return (handoff.stamp - unlocked);
}

/* The handoff's samples, after its warm-up, for across_cell; B is its probe's call. */
static size_t
handoff_samples(erx_bench_cell_t *cell)
{
	const uint32_t total = ERX_BENCH_FAST_WARMUP + ERX_BENCH_FAST_SAMPLES;
	const uint64_t wait = (clock_hz + HANDOFF_WAITS_PER_SECOND - 1) / HANDOFF_WAITS_PER_SECOND;
	pthread_t b;
	size_t taken = 0;

	atomic_store(&handoff.go, 0);
	atomic_store(&handoff.about, 0);
	atomic_store(&handoff.done, 0);
	atomic_store(&handoff.wrong, false);
	refusal.call = NULL;
	if (!thread_try_start(&b, cpus - 1, true, handoff_b, total)) {
		const peer_run_t run = probe_refused();

		cell->status = run.status;
		cell->reason = run.reason;
		return (0);
	}
	for (uint32_t number = 1; number <= total; number++) {
		const uint64_t sample = handoff_sample(number, wait);

		if (number > ERX_BENCH_FAST_WARMUP)
			samples[taken++] = sample;
	}
	peer_thread_join(b);
	if (atomic_load(&handoff.wrong)) {
		cell->status = "failed";
		cell->reason = WRONG_RESULT;
	}
	return (taken);
}

/* Memory: areas of pages, each its own anonymous private mapping. */

static size_t
area_bytes(void)
{
	return ((size_t)posix.pages * page_bytes);
}

static uint8_t *
area_page(uint64_t area, uint64_t page)
{
	return (vm_pages[area] + page * page_bytes);
}

static bool
area_map(uint64_t at)
{
	void *const area = mmap(NULL, area_bytes(), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);

	vm_pages[at] = area == MAP_FAILED ? NULL : area;
	return (posix_ok("mmap", area == MAP_FAILED ? -1 : 0));
}

/* Unmaps area at, keeping its address for unmapped. */
static bool
area_unmap(uint64_t at)
{
	return (posix_ok("munmap", munmap(vm_pages[at], area_bytes())));
}

/* Every page of area at reads zero, at both ends. */
static bool
area_blank(uint64_t at)
{
	for (uint64_t page = 0; page < posix.pages; page++)
		if (!page_blank(area_page(at, page)))
			return (false);
	return (true);
}

static bool
area_blank_unmap(uint64_t at)
{
	const bool blank = area_blank(at);

	return (area_unmap(at) && blank);
}

static bool
munmap_act(uint64_t at)
{
#if defined(ERX_PEER_SEED_NOOP_MUNMAP)
	/* The seeded fault: munmap does nothing, so the mprotect after it succeeds. */
	(void)at;
	return (true);
#else
	return (area_unmap(at));
#endif
}

/* mprotect of area at's range fails with ENOMEM, POSIX's answer for an unmapped page. */
static bool
unmapped(uint64_t at)
{
	const int answer = mprotect(vm_pages[at], area_bytes(), PROT_READ);

	if (answer == -1 && errno == ENOMEM)
		return (true);
	/* A refusal is kept for the probe; a success is a munmap that did nothing. */
	(void)posix_ok("mprotect", answer);
	return (false);
}

/* touch: a sample is a page; operation at writes page at % pages of area at / pages. */
static uint64_t touch_written[ERX_BENCH_BATCH_MAX];

static bool
touch_prepare(uint64_t at)
{
	const uint64_t area = at / posix.pages;

	if (at % posix.pages == 0) {
		if (!area_map(area))
			return (false);
		touch_written[area] = 0;
	}
	touch_written[area]++;
	return (true);
}

static bool
touch_page(uint64_t at)
{
	page_fill(area_page(at / posix.pages, at % posix.pages), at);
	return (true);
}

/* At an area's first operation, once every write is done: its pages read back, then it is unmapped. */
static bool
touch_undo(uint64_t at)
{
	const uint64_t area = at / posix.pages;
	bool right = true;

	if (at % posix.pages != 0)
		return (true);
	for (uint64_t page = 0; right && page < touch_written[area]; page++)
		right = page_holds(area_page(area, page), at + page);
	return (area_unmap(area) && right);
}

static bool
area_fill(uint64_t at)
{
	for (uint64_t page = 0; page < posix.pages; page++)
		page_fill(area_page(at, page), page);
	return (true);
}

static bool
map_cycle(uint64_t at)
{
	return (area_map(at) && area_fill(at) && area_unmap(at));
}

/* map-cycle's checks, untimed: the pages read zero, then their writes, and the range is unmapped. */
static bool
cycle_check(void)
{
	bool right = area_map(0) && area_blank(0) && area_fill(0);

	for (uint64_t page = 0; right && page < posix.pages; page++)
		right = page_holds(area_page(0, page), page);
	return (right && area_unmap(0) && unmapped(0));
}

/* The cells, in tools/lib/erx/benches/posix.rb's order; mutex-handoff is posix_run's. */

#define PARAMS(...)							\
	.params = (const erx_bench_param_t[]){ __VA_ARGS__ },		\
	.nparams = sizeof((const erx_bench_param_t[]){ __VA_ARGS__ }) / sizeof(erx_bench_param_t)
#define BYTES(n)	{ .name = "bytes", .count = (n) }
#define PAGES(n)	{ .name = "pages", .count = (n) }
#define PEER_THREAD	{ .name = "peer", .text = "thread" }
#define NS(n)		{ .name = "ns", .count = (n) }
#define BIG_BYTES	UINT64_C(16777216)
#define STREAM_BYTES	UINT64_C(67108864)

static const posix_cell_t posix_cells[] = {
	{ "getpid", "same-cpu", .op = { nothing, getpid_same, nothing }, .begin = getpid_begin },
	{ "clock-gettime", "same-cpu", .op = { nothing, clock_forward, nothing } },
	{ "open", "same-cpu", .op = { nothing, open_lowest, close_opened }, .begin = lowest_begin,
	  .check = lowest_check },
	{ "close", "same-cpu", .op = { open_lowest, close_opened, nothing }, .begin = lowest_begin,
	  .check = lowest_check },
	{ "fstat", "same-cpu", .op = { nothing, fstat_file, nothing }, .begin = read_begin, .end = file_end },
	{ "stat", "same-cpu", .op = { nothing, stat_path, nothing }, .begin = made_begin },
	{ "read", "same-cpu", PARAMS(BYTES(4096)), .op = { nothing, pread_first, nothing }, .begin = read_begin,
	  .end = file_end, .check = read_check },
	{ "read", "same-cpu", PARAMS(BYTES(65536)), .op = { nothing, pread_first, nothing }, .begin = read_begin,
	  .end = file_end, .check = read_check },
	{ "write", "same-cpu", PARAMS(BYTES(4096)), .op = { nothing, pwrite_first, nothing }, .begin = write_begin,
	  .end = file_end, .check = write_check },
	{ "write", "same-cpu", PARAMS(BYTES(65536)), .op = { nothing, pwrite_first, nothing }, .begin = write_begin,
	  .end = file_end, .check = write_check },
	{ "read-seq", "same-cpu", PARAMS(BYTES(BIG_BYTES)), .expensive = true, .op = { nothing, read_through, nothing },
	  .begin = big_read_begin, .end = file_end },
	{ "write-seq", "same-cpu", PARAMS(BYTES(BIG_BYTES)), .expensive = true,
	  .op = { nothing, write_through, nothing }, .begin = big_write_begin, .end = file_end },
	{ "copy", "same-cpu", PARAMS(BYTES(BIG_BYTES)), .expensive = true, .op = { nothing, copy_through, nothing },
	  .begin = copy_begin, .check = copy_check },
	{ "pipe-rtt", "same-cpu", PARAMS(PEER_THREAD, BYTES(1)), .op = { nothing, round_trip, nothing },
	  .peer = true, .begin = rtt_begin, .end = pipes_end },
	{ "pipe-rtt", "same-cpu", PARAMS(PEER_THREAD, BYTES(65536)), .op = { nothing, round_trip, nothing },
	  .peer = true, .begin = rtt_begin, .end = pipes_end },
	{ "pipe-rtt", "cross-cpu", PARAMS(PEER_THREAD, BYTES(1)), .op = { nothing, round_trip, nothing },
	  .peer = true, .begin = rtt_begin, .end = pipes_end },
	{ "pipe-rtt", "cross-cpu", PARAMS(PEER_THREAD, BYTES(65536)), .op = { nothing, round_trip, nothing },
	  .peer = true, .begin = rtt_begin, .end = pipes_end },
	{ "poll-rtt", "same-cpu", PARAMS(PEER_THREAD, BYTES(1)), .op = { nothing, round_trip, nothing },
	  .peer = true, .begin = poll_begin, .end = pipes_end },
	{ "pipe-stream", "same-cpu", PARAMS(PEER_THREAD, BYTES(STREAM_BYTES)), .expensive = true,
	  .op = { nothing, stream_one, nothing }, .peer = true, .begin = stream_begin, .end = pipes_end },
	{ "cond-pingpong", "same-cpu", .op = { nothing, pingpong_turn, nothing },
	  .peer = true, .begin = pingpong_begin, .end = pingpong_end },
	{ "poll-rtt", "cross-cpu", PARAMS(PEER_THREAD, BYTES(1)), .op = { nothing, round_trip, nothing },
	  .peer = true, .begin = poll_begin, .end = pipes_end },
	{ "pipe-stream", "cross-cpu", PARAMS(PEER_THREAD, BYTES(STREAM_BYTES)), .expensive = true,
	  .op = { nothing, stream_one, nothing }, .peer = true, .begin = stream_begin, .end = pipes_end },
	{ "cond-pingpong", "cross-cpu", .op = { nothing, pingpong_turn, nothing },
	  .peer = true, .begin = pingpong_begin, .end = pingpong_end },
	{ "thread-create-join", "same-cpu", .op = { nothing, create_join, nothing } },
	{ "nanosleep", "same-cpu", PARAMS(NS(1000000)), .expensive = true,
	  .op = { nothing, sleep_once, nothing } },
	{ "mmap", "same-cpu", PARAMS(PAGES(1)), .op = { nothing, area_map, area_blank_unmap } },
	{ "mmap", "same-cpu", PARAMS(PAGES(64)), .op = { nothing, area_map, area_blank_unmap } },
	{ "munmap", "same-cpu", PARAMS(PAGES(1)), .op = { area_map, munmap_act, unmapped } },
	{ "munmap", "same-cpu", PARAMS(PAGES(64)), .op = { area_map, munmap_act, unmapped } },
	{ "touch", "same-cpu", PARAMS(PAGES(64)), .op = { touch_prepare, touch_page, touch_undo } },
	{ "map-cycle", "same-cpu", PARAMS(PAGES(64)), .op = { nothing, map_cycle, nothing }, .check = cycle_check },
};

/*
 * Runs one cell and prints it: unsupported where its threads are not pinned and it times a
 * peer, and on one CPU across CPUs; else as its probe and run leave it.
 */
static void
posix_cell_run(const posix_cell_t *spec)
{
	erx_bench_cell_t cell = peer_cell(spec->operation, spec->placement);
	peer_run_t run;

	cell.params = spec->params;
	cell.nparams = spec->nparams;
	cell.raw = spec->expensive ? samples : NULL;
	if (unpinned && spec->peer) {
		cell.status = "unsupported";
		cell.reason = UNPINNED;
		peer_print(cell, samples, 0);
		return;
	}
	if (strcmp(spec->placement, "cross-cpu") == 0 && cpus == 1) {
		cell.status = "unsupported";
		cell.reason = ONE_CPU;
		peer_print(cell, samples, 0);
		return;
	}
	posix_load(spec);
	refusal.call = NULL;
	if (spec->begin != NULL && !spec->begin())
		run = probe_refused();
	else
		run = spec->expensive ? expensive_run(&spec->op) : fast_run(&spec->op);
	if (run.reason == NULL && posix.ns != 0)
		sleep_less(&cell, &run);
	run_print(cell, run, spec->check);
	if (spec->end != NULL)
		spec->end();
}

static void
posix_run(void)
{
	erx_bench_pair_t pair;

	for (size_t at = 0; at < sizeof(pattern); at++)
		pattern[at] = (uint8_t)(at * 131u + (at >> 8) + 7u);
	pin_to(0);
	for (size_t at = 0; at < sizeof(posix_cells) / sizeof(posix_cells[0]); at++)
		posix_cell_run(&posix_cells[at]);
	/* unlink may be refused where the program layer lacks it; the files then stay in /tmp. */
	(void)unlink(POSIX_FILE);
	(void)unlink(POSIX_BIG);
	(void)unlink(POSIX_COPY);
	if (cpus == 1 || unpinned) {
		peer_print_unsupported("mutex-handoff", "cross-cpu", unpinned ? UNPINNED : ONE_CPU);
		print_clock(NULL, 0);
		return;
	}
	pair = across_cell(peer_cell("mutex-handoff", "cross-cpu"), handoff_samples);
	print_clock(&pair, 1);
}

#if !defined(ERX_PEER_ERXOS)
static void nullcall_run(void) { calibrated(nullcall_cells); }
static void vm_run(void) { calibrated(vm_cells); }
static void sched_run(void) { calibrated(share_equal); }
#endif

/* The benchmarks; posix is given the CPU count, and may be told to pin nothing; the others ask the system. */
static const struct {
	const char *name;
	void (*run)(void);
	bool given_cpus;
} benchmarks[] = {
#if !defined(ERX_PEER_ERXOS)
	{ "nullcall", nullcall_run, false },
	{ "vm", vm_run, false },
	{ "wake", wake_run, false },
	{ "sched", sched_run, false },
	{ "xdomain", xdomain_run, false },
#endif
	{ "posix", posix_run, true },
};

/* The CPU count a posix run is given, 1 to 256, or 0 for any other argument. */
static long
cpus_given(const char *text)
{
#if defined(ERX_PEER_SEED_SYSCONF_CPUS)
	/* The seeded fault: the count the system answers, which on erXos is 1 whatever the machine. */
	(void)text;
	return (sysconf(_SC_NPROCESSORS_ONLN));
#else
	char *end;
	unsigned long count;

	if (text[0] < '1' || text[0] > '9')
		return (0);
	errno = 0;
	count = strtoul(text, &end, 10);
	return (errno == 0 && *end == '\0' && count <= 256 ? (long)count : 0);
#endif
}

int
main(int argc, char **argv)
{
	const size_t count = sizeof(benchmarks) / sizeof(benchmarks[0]);
	const long page = sysconf(_SC_PAGESIZE);
	size_t chosen = count;
	long online = 0;
	int wanted = 2;

	for (size_t at = 0; argc >= 2 && at < count; at++)
		if (strcmp(argv[1], benchmarks[at].name) == 0)
			chosen = at;
	/* A run given the CPU count takes it after the name, and "unpinned" after it. */
	if (chosen < count && benchmarks[chosen].given_cpus) {
		unpinned = argc == 4 && strcmp(argv[3], "unpinned") == 0;
		wanted = unpinned ? 4 : 3;
	}
	if (chosen < count && argc == wanted)
		online = benchmarks[chosen].given_cpus ? cpus_given(argv[2]) : 1;
	if (online == 0) {
#if !defined(ERX_PEER_ERXOS)
		fputs("usage: erx_peer_bench nullcall|vm|wake|sched|xdomain\n", stderr);
#endif
		fputs("usage: erx_peer_bench posix CPUS [unpinned], CPUS from 1 to 256\n", stderr);
		return (2);
	}
	if (!benchmarks[chosen].given_cpus)
		online = sysconf(_SC_NPROCESSORS_ONLN);
	if (online < 1 || online > 256 || page < 64)
		peer_fail("the CPU count or the page size did not read");
	benchmark = benchmarks[chosen].name;
	cpus = (unsigned)online;
	page_bytes = (size_t)page;
	/* A write to an echo that ended fails with EPIPE, which the run reports. */
	signal(SIGPIPE, SIG_IGN);
	/* The run ends by SIGALRM at its deadline, so a stalled side ends it with no CLOCK line. */
	alarm(ERX_PEER_RUN_DEADLINE_S);
	clock_choose();
	erx_bench_read_pairs(clock_read, read_pairs, READ_PAIRS);
	peer_say("erx: bench: timing\n");
	benchmarks[chosen].run();
	peer_say("erx: bench: done\n");
	return (0);
}
