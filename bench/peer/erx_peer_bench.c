/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_peer_bench: the POSIX counterparts of the native bench guest's cells, for the other
 * systems erXos is compared with (docs/design-bench.md, "Other systems on the same
 * Raspberry Pi 4"). One run times one benchmark, as one boot of the native bench image
 * does, and prints its BENCH lines (and a sustained cell's WINDOW lines) and then one
 * CLOCK line, the lines the guests print, through the guests' own line library, so
 * tools/lib/erx/bench_measurement.rb reads every system alike:
 *
 *	erx_peer_bench nullcall|vm|wake|sched|xdomain
 *
 * It is the one file the other system's compiler is given; it includes the guests' line,
 * histogram, clock, sweep and window sources, which come with it from the tree's
 * test/guest/bench and liberx/backend/core/mem.h. The profiles' sizes and the xdomain
 * cells' parameters are the build's, as tools/lib/erx/peer_bench.rb derives them:
 *
 *	cc -std=c17 -O2 -pthread -I ROOT $(PeerBench.flags) ROOT/bench/peer/erx_peer_bench.c
 *
 * Every interval is ticks of one clock: the architecture's system counter where user mode
 * may read it, clock "counter", and otherwise CLOCK_MONOTONIC in nanoseconds, clock
 * "monotonic". Threads are pinned with sched_setaffinity on Linux and cpuset_setaffinity
 * on FreeBSD, the one place the file differs by system. The main thread of a native-set
 * benchmark runs on CPU 0, the service's CPU, and the pair its CLOCK line calibrates is
 * CPU 0 and the last, as a native boot's is; an xdomain run is not pinned.
 *
 * An operation the design's counterparts table names no counterpart for is reported
 * unsupported, never timed as something else. A setup failure prints a FAILED line and
 * ends the run with no CLOCK line, so the host rejects the run rather than read part of it.
 */

#if defined(__linux__)
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <pthread.h>
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
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>

#if defined(__FreeBSD__)
#include <sys/param.h>
#include <sys/cpuset.h>
#elif !defined(__linux__)
#error "erx_peer_bench pins threads on Linux and FreeBSD only"
#endif

#include "test/guest/bench/bench_hist.c"
#include "test/guest/bench/bench_clock.c"
#include "test/guest/bench/bench_periodic.c"
#include "test/guest/bench/bench_window.c"
#include "test/guest/bench/bench_line.c"

#if !defined(ERX_BENCH_FAST_WARMUP) || !defined(ERX_BENCH_FAST_SAMPLES) || !defined(ERX_BENCH_PERIODIC_SAMPLES) || \
    !defined(ERX_BENCH_SUSTAINED_SAMPLES) || !defined(ERX_BENCH_SUSTAINED_WARMUP_MS) ||                              \
    !defined(ERX_PEER_XDOMAIN_BYTES) || !defined(ERX_PEER_XDOMAIN_ENCODED)
#error "the build passes the landing profiles' sizes and the xdomain cells' parameters"
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
/* share-equal's landing cell's parameters, which tools/lib/erx/benches/sched.rb declares. */
#define SHARE_THREADS	4u
#define SHARE_WINDOW_MS	1000u
/*
 * A spinner's gap longer than half of this slice is a lost turn: the slice erXos's root
 * configures, since POSIX schedulers configure none, so a lost turn means the same on
 * every system.
 */
#define SHARE_SLICE_US	UINT64_C(1000)
#define NO_COUNTERPART	"no counterpart named in the design"
#define ONE_CPU		"the machine has one CPU"

/* The run's clock: its name as the lines give it, its frequency and its read. */
static const char *clock_name;
static uint64_t clock_hz;
static uint64_t (*clock_read)(void);

static unsigned cpus;
static const char *benchmark;
static size_t page_bytes;

static char line[LINE_BYTES];
static erx_bench_hist_t hist;
static erx_bench_reads_t read_pairs[READ_PAIRS];
static erx_bench_token_t token;
static erx_bench_round_t rounds[ROUNDS];
static uint64_t samples[ERX_BENCH_FAST_SAMPLES > ERX_BENCH_PERIODIC_SAMPLES ? ERX_BENCH_FAST_SAMPLES :
    ERX_BENCH_PERIODIC_SAMPLES];

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

static void
clock_choose(void)
{
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
}

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

/* Pinning. */

static void
pin_to(unsigned cpu)
{
#if defined(__linux__)
	cpu_set_t set;

	CPU_ZERO(&set);
	CPU_SET(cpu, &set);
	if (sched_setaffinity(0, sizeof(set), &set) != 0)
		peer_fail("a thread could not be pinned");
#else
	cpuset_t set;

	CPU_ZERO(&set);
	CPU_SET(cpu, &set);
	if (cpuset_setaffinity(CPU_LEVEL_WHICH, CPU_WHICH_TID, -1, sizeof(set), &set) != 0)
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

/* Starts entry(index) on a new thread, pinned to cpu where pinned is set. */
static pthread_t
thread_start(unsigned cpu, bool pinned, void (*entry)(uint64_t), uint64_t index)
{
	peer_start_t *const start = malloc(sizeof(*start));
	pthread_t thread;

	if (start == NULL)
		peer_fail("no memory for a thread");
	*start = (peer_start_t){ .cpu = cpu, .pinned = pinned, .entry = entry, .index = index };
	if (pthread_create(&thread, NULL, peer_thread_main, start) != 0)
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
	offset = erx_bench_offset(rounds, ROUNDS, erx_bench_read_calibration(read_pairs, READ_PAIRS, &hist).increment);
	return (offset);
}

static void
print_clock(const erx_bench_pair_t *pair, size_t npairs)
{
	const erx_bench_read_cal_t reads = erx_bench_read_calibration(read_pairs, READ_PAIRS, &hist);
	/* A timed wait takes its deadline in nanoseconds, so it rounds to one. */
	const erx_bench_calibration_t clock = { .clock = clock_name, .frequency_hz = clock_hz,
	    .increment = reads.increment, .read_cost = reads.read_cost,
	    .wait_rounding = (clock_hz + NS_PER_SECOND - 1) / NS_PER_SECOND, .cycles_per_tick_milli = 0,
	    .pairs = pair, .npairs = npairs };

	peer_print_line(erx_bench_line_clock(line, sizeof(line), &clock));
}

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

/*
 * A fast cell's run (docs/design-bench.md, "Short operations"): ERX_BENCH_FAST_WARMUP
 * batches of one, then ERX_BENCH_FAST_SAMPLES batches of the size the warm-up's median
 * asks, each prepared untimed, its operations timed back to back and undone untimed. A
 * sample is a batch's mean. Each step answers whether it gave the right result.
 */
typedef struct {
	bool (*prepare)(uint64_t at);
	bool (*act)(uint64_t at);
	bool (*undo)(uint64_t at);
} peer_op_t;

typedef struct {
	uint64_t batch;
	size_t taken;
	bool wrong;
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

static peer_run_t
fast_run(const peer_op_t *op)
{
	peer_run_t run = { .batch = 1, .taken = 0, .wrong = false };
	uint64_t ticks;

	for (size_t at = 0; at < ERX_BENCH_HIST_BUCKETS; at++)
		hist.count[at] = 0;
	hist.samples = 0;
	for (uint32_t warm = 0; warm < ERX_BENCH_FAST_WARMUP; warm++) {
		if (!batch_run(op, 1, &ticks)) {
			run.wrong = true;
			return (run);
		}
		erx_bench_hist_add(&hist, ticks);
	}
	run.batch = erx_bench_batch_for(erx_bench_hist_median(&hist));
	for (; run.taken < ERX_BENCH_FAST_SAMPLES; run.taken++) {
		if (!batch_run(op, run.batch, &ticks)) {
			run.wrong = true;
			return (run);
		}
		samples[run.taken] = ticks / run.batch;
	}
	return (run);
}

/* Times op and prints its cell: failed with a wrong result, or when its untimed check is false. */
static void
fast_cell(const char *operation, const char *placement, const erx_bench_param_t *params, size_t nparams,
    const peer_op_t *op, bool (*check)(void))
{
	erx_bench_cell_t cell = peer_cell(operation, placement);
	const peer_run_t run = fast_run(op);

	cell.params = params;
	cell.nparams = nparams;
	cell.batch = run.batch;
	if (run.wrong) {
		cell.status = "failed";
		cell.reason = "wrong result";
	} else if (check != NULL && !check()) {
		cell.status = "failed";
		cell.reason = "the untimed check failed";
	}
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

/* Echoes messages of size bytes from in to out until in ends. */
static void
echo(int in, int out, size_t size)
{
	uint8_t message[ERX_PEER_XDOMAIN_BYTES > 8 ? ERX_PEER_XDOMAIN_BYTES : 8];

	while (read_full(in, message, size) && write_full(out, message, size))
		continue;
}

/* The near end of a round trip: where the request goes and the reply comes from. */
static int trip_out = -1, trip_in = -1;
static size_t trip_bytes;
static uint8_t trip_request[ERX_PEER_XDOMAIN_BYTES > 8 ? ERX_PEER_XDOMAIN_BYTES : 8];

/* One round trip: the request out, the reply in, equal to the request. */
static bool
round_trip(uint64_t at)
{
	uint8_t reply[sizeof(trip_request)];

	(void)at;
	return (write_full(trip_out, trip_request, trip_bytes) && read_full(trip_in, reply, trip_bytes) &&
	    memcmp(reply, trip_request, trip_bytes) == 0);
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

/* nullcall: getppid for kernel, and an 8-byte pipe round trip for root-cross-space. */

static pid_t parent_pid;

static bool
ppid_call(uint64_t at)
{
	(void)at;
	return (getppid() == parent_pid);
}

/* root-cross-space from CPU 0 to an echo process on echo_cpu, over two pipes. */
static void
pipe_cell(const char *placement, unsigned echo_cpu)
{
	static const peer_op_t op = { nothing, round_trip, nothing };
	int there[2], back[2];
	pid_t child;

	if (pipe(there) != 0 || pipe(back) != 0)
		peer_fail("no pipe");
	trip_bytes = 8;
	memset(trip_request, 0xa5, trip_bytes);
	/* The echo holds back[0] too, which it never reads; there[1]'s close alone ends it. */
	child = echo_process(there[0], back[1], there[1], echo_cpu, true);
	close(there[0]);
	close(back[1]);
	trip_out = there[1];
	trip_in = back[0];
	fast_cell("root-cross-space", placement, NULL, 0, &op, NULL);
	echo_reap(child);
}

static void
nullcall_cells(void)
{
	static const peer_op_t kernel = { nothing, ppid_call, nothing };

	parent_pid = getppid();
	peer_print_unsupported("root-same-space", "service-cpu", NO_COUNTERPART);
	peer_print_unsupported("root-same-space", "other-cpu", NO_COUNTERPART);
	pipe_cell("service-cpu", 0);
	if (cpus > 1)
		pipe_cell("other-cpu", cpus - 1);
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

/* A write to page, which must end the process that makes it with SIGSEGV or SIGBUS. */
static bool
write_faults(uint8_t *page)
{
	const struct rlimit no_core = { 0, 0 };
	const pid_t child = fork();
	int status;

	if (child < 0)
		peer_fail("no process for the protect check");
	if (child == 0) {
		(void)setrlimit(RLIMIT_CORE, &no_core);
		page_fill(page, 1);
		_exit(0);
	}
	while (waitpid(child, &status, 0) < 0)
		if (errno != EINTR)
			peer_fail("the protect check's process could not be reaped");
	return (WIFSIGNALED(status) && (WTERMSIG(status) == SIGSEGV || WTERMSIG(status) == SIGBUS));
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
	bool refused = false;

	for (size_t n = 0; n < ERX_BENCH_PERIODIC_SAMPLES && !refused; n++) {
		const struct timespec at = monotonic_at(erx_bench_periodic_deadline(first, period, k));
		int answer;

		while ((answer = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &at, NULL)) == EINTR)
			continue;
		stamps[n] = (erx_bench_stamp_t){ .k = k, .returned = clock_read() };
		refused = answer != 0;
		k = erx_bench_periodic_next(first, period, k, stamps[n].returned);
	}
	erx_bench_periodic_classify(first, period, stamps, ERX_BENCH_PERIODIC_SAMPLES, &periodic);
	for (size_t at = 0; at < ERX_BENCH_PERIODIC_SAMPLES; at++) {
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

/* The handshake A and B share: the sample B waits for, the one A signalled, B's stamp. */
static struct {
	pthread_mutex_t lock;
	pthread_cond_t poke;
	pthread_cond_t answer;
	uint32_t waiting;
	uint32_t poked;
	uint32_t done;
	bool lost;
	uint64_t stamp;
} shake = { .lock = PTHREAD_MUTEX_INITIALIZER };

/* B's side: for each sample, wait to be poked, stamp, answer; a wait that times out is a lost wake. */
static void
wake_b(uint64_t total)
{
	if (pthread_mutex_lock(&shake.lock) != 0)
		peer_fail("the handshake's lock was refused");
	for (uint32_t number = 1; number <= total && !shake.lost; number++) {
		struct timespec patience;

		if (clock_gettime(CLOCK_MONOTONIC, &patience) != 0)
			peer_fail("CLOCK_MONOTONIC did not read");
		patience.tv_sec += WAKE_PATIENCE_S;
		shake.waiting = number;
		pthread_cond_signal(&shake.answer);
		while (shake.poked != number && !shake.lost)
			shake.lost = pthread_cond_timedwait(&shake.poke, &shake.lock, &patience) == ETIMEDOUT &&
			    shake.poked != number;
		shake.stamp = clock_read();
		shake.done = number;
		pthread_cond_signal(&shake.answer);
	}
	pthread_mutex_unlock(&shake.lock);
}

/* A's side: per sample, once B waits, stamp and poke, then take B's stamp less A's. */
static size_t
wake_a(uint32_t total, uint64_t *raw)
{
	size_t taken = 0;

	if (pthread_mutex_lock(&shake.lock) != 0)
		peer_fail("the handshake's lock was refused");
	for (uint32_t number = 1; number <= total && !shake.lost; number++) {
		uint64_t poked;

		while (shake.waiting != number && !shake.lost)
			pthread_cond_wait(&shake.answer, &shake.lock);
		poked = clock_read();
		shake.poked = number;
		pthread_cond_signal(&shake.poke);
		while (shake.done != number)
			pthread_cond_wait(&shake.answer, &shake.lock);
		if (number > ERX_BENCH_FAST_WARMUP && !shake.lost)
			raw[taken++] = shake.stamp - poked;
	}
	pthread_mutex_unlock(&shake.lock);
	return (taken);
}

static void
handshake_init(void)
{
	pthread_condattr_t monotonic;

	if (pthread_condattr_init(&monotonic) != 0 || pthread_condattr_setclock(&monotonic, CLOCK_MONOTONIC) != 0 ||
	    pthread_cond_init(&shake.poke, &monotonic) != 0 || pthread_cond_init(&shake.answer, NULL) != 0)
		peer_fail("no condition variable");
	pthread_condattr_destroy(&monotonic);
}

/* wake-cross-cpu, calibrated before and after; returns the pair for the CLOCK line. */
static erx_bench_pair_t
wake_cross_cpu(void)
{
	const uint32_t total = ERX_BENCH_FAST_WARMUP + ERX_BENCH_FAST_SAMPLES;
	erx_bench_cell_t cell = peer_cell("wake-cross-cpu", "cross-cpu");
	erx_bench_pair_t pair = { .cpus = { 0, cpus - 1 } };
	erx_bench_sample_t top[ERX_BENCH_LARGEST];
	erx_bench_offset_t hull;
	const char *unsupported;
	pthread_t b;
	size_t taken;
	int64_t middle;

	handshake_init();
	pair.before = calibrate();
	b = peer_thread_start(cpus - 1, wake_b, total);
	taken = wake_a(total, samples);
	peer_thread_join(b);
	pair.after = calibrate();
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
	if (shake.lost) {
		/* A failure keeps its counts, not statistics no calibration vouches for. */
		cell.status = "failed";
		cell.reason = "lost wake";
		cell.lost = 1;
		taken = 0;
	} else if (unsupported != NULL) {
		peer_print_unsupported("wake-cross-cpu", "cross-cpu", unsupported);
		return (pair);
	} else {
		cell.has_uncertainty = true;
		cell.uncertainty = erx_bench_offset_half_width(hull);
	}
	peer_print(cell, samples, taken);
	return (pair);
}

static void
wake_run(void)
{
	erx_bench_pair_t pair;

	pin_to(0);
	park_deadline();
	peer_print_unsupported("wake-same-cpu", "same-cpu", NO_COUNTERPART);
	peer_print_unsupported("trigger-take", "same-cpu", NO_COUNTERPART);
	if (cpus == 1) {
		peer_print_unsupported("wake-cross-cpu", "cross-cpu", ONE_CPU);
		print_clock(NULL, 0);
		return;
	}
	pair = wake_cross_cpu();
	print_clock(&pair, 1);
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

static int echo_fd = -1;

static void
echo_thread(uint64_t index)
{
	(void)index;
	echo(echo_fd, echo_fd, trip_bytes);
}

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
	echo_fd = ends[1];
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

static void nullcall_run(void) { calibrated(nullcall_cells); }
static void vm_run(void) { calibrated(vm_cells); }
static void sched_run(void) { calibrated(share_equal); }

static const struct {
	const char *name;
	void (*run)(void);
} benchmarks[] = {
	{ "nullcall", nullcall_run },
	{ "vm", vm_run },
	{ "wake", wake_run },
	{ "sched", sched_run },
	{ "xdomain", xdomain_run },
};

int
main(int argc, char **argv)
{
	const long online = sysconf(_SC_NPROCESSORS_ONLN), page = sysconf(_SC_PAGESIZE);
	void (*run)(void) = NULL;

	for (size_t at = 0; argc == 2 && at < sizeof(benchmarks) / sizeof(benchmarks[0]); at++)
		if (strcmp(argv[1], benchmarks[at].name) == 0) {
			benchmark = benchmarks[at].name;
			run = benchmarks[at].run;
		}
	if (run == NULL) {
		fputs("usage: erx_peer_bench nullcall|vm|wake|sched|xdomain\n", stderr);
		return (2);
	}
	if (online < 1 || online > 256 || page < 64)
		peer_fail("the CPU count or the page size did not read");
	cpus = (unsigned)online;
	page_bytes = (size_t)page;
	/* A write to an echo that ended fails with EPIPE, which the run reports. */
	signal(SIGPIPE, SIG_IGN);
	clock_choose();
	erx_bench_read_pairs(clock_read, read_pairs, READ_PAIRS);
	peer_say("erx: bench: timing\n");
	run();
	peer_say("erx: bench: done\n");
	return (0);
}
