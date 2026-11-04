/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The threads transcript: a root task that creates and starts threads through the
 * service and waits on words, and reports each case on one line, which
 * tools/lib/erx/native_threads.rb judges. Each thread runs on the next CPU in turn,
 * so a run at four CPUs wakes and deletes across them. The early cases' threads
 * park on a word that never changes; the loops' threads exit, and the last cases
 * use up what indices remain and end the first thread.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/park.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/umtx.h"
#include "liberx/backend/fiasco/vm.h"

#define STACKS		64u
#define STACK_BYTES	16384u
#define MANY_THREADS	32u
#define START_STEPS	3u
#define PING_ROUNDS	2000u
#define RACE_ROUNDS	2000u
#define JOIN_ROUNDS	10000u
#define DETACHED_ROUNDS	500u
#define DETACHED_PAGES	4u
#define PARK_ROUNDS	2000u
#define PARK_EXECUTORS	2u
#define CPUS_MAX	16u
#define HOG_PRIORITY	100u
#define NORMAL_PRIORITY	1u
#define HOG_TRIES	5u
#define HOG_NS		(UINT64_C(50) * NS_PER_MS)
#define NS_PER_MS	UINT64_C(1000000)
#define PATIENCE_NS	(UINT64_C(60000) * NS_PER_MS)
#define QUEUE_SETTLE_NS	(UINT64_C(50) * NS_PER_MS)
#define TLS_VALUE	UINT64_C(0x5a5a00001234beef)
#define ARG_VALUE	UINT64_C(0x1122334455667788)

void erx_fiasco_root_main(void);

static _Alignas(16) uint8_t stacks[STACKS][STACK_BYTES];
static uint32_t stacks_used;
static _Atomic uint32_t never;

/* What the helpers report. */
static _Atomic uint32_t done;
static _Atomic uint32_t ready;
static uint64_t seen_tls, seen_arg, seen_stack;
static _Atomic uint32_t order[4];
static _Atomic uint32_t order_next;
static _Atomic uint32_t gate_word;
static _Atomic uint32_t turn;
static _Atomic uint32_t race_word;
static _Atomic uint32_t race_stop;
static _Atomic uint32_t race_stale;
static _Atomic uint32_t memory_failed;
static uint32_t cpu_count;
static uint32_t cpu_next;

static void
say(const char *text)
{
	size_t length = 0;

	while (text[length] != '\0')
		length++;
	erx_fiasco_console_write(text, length);
}

static void
report(const char *name, bool ok)
{
	say("erx: threads: ");
	say(name);
	say(ok ? " ok\n" : " FAILED\n");
}

static uint64_t
word_addr(const _Atomic uint32_t *word)
{
	return ((uint64_t)(uintptr_t)word);
}

static _Noreturn void
park(void)
{
	for (;;)
		(void)erx_umtx_wait(word_addr(&never), 0, ERX_FIASCO_UMTX_FOREVER);
}

static void
bump_done(void)
{
	atomic_fetch_add_explicit(&done, 1, memory_order_release);
	(void)erx_umtx_wake(word_addr(&done), 128);
}

/* Waits until *word holds want, within the patience every case shares. */
static bool
wait_for(_Atomic uint32_t *word, uint32_t want)
{
	const uint64_t deadline = erx_fiasco_clock_ns() + PATIENCE_NS;
	uint32_t value;

	while ((value = atomic_load_explicit(word, memory_order_acquire)) != want)
		if (erx_umtx_wait(word_addr(word), value, deadline) == ERX_ETIMEDOUT)
			return (false);
	return (true);
}

static void
say_number(uint64_t value)
{
	char digits[21];
	size_t at = sizeof(digits);

	digits[--at] = '\0';
	do {
		digits[--at] = (char)('0' + value % 10);
		value /= 10;
	} while (value != 0);
	say(digits + at);
}

/* A thread on the given stack and the next CPU in turn, not started yet. */
static int
create_on(uint64_t stack_top, void (*entry)(uint64_t), uint64_t arg, uint64_t tls, uint64_t thread_class,
    uint64_t *thread)
{
	erx_fiasco_start_t start = { 0 };
	const uint64_t *const words = (const uint64_t *)(const void *)&start;
	erx_utcb_t *const utcb = erx_utcb_self();
	int status;

	start.regs.gpr[0] = arg;
	start.regs.sp = stack_top;
	start.regs.pc = (uint64_t)(uintptr_t)entry;
	start.tls = tls;
	for (size_t word = 0; word < sizeof(start) / sizeof(uint64_t); word++)
		atomic_store_explicit(&utcb->mr[word], words[word], memory_order_relaxed);
	status = erx_thread_create(0, 0, 0, thread_class, thread);
	if (status != ERX_OK)
		return (status);
	return (erx_thread_set_affinity(*thread, UINT64_C(1) << (cpu_next++ % cpu_count)));
}

/* As above on a stack of its own, for a thread that never gives it back. */
static int
create_class(void (*entry)(uint64_t), uint64_t arg, uint64_t tls, uint64_t thread_class, uint64_t *thread)
{
	if (stacks_used >= STACKS)
		return (ERX_ENOMEM);
	stacks_used++;
	return (create_on((uint64_t)(uintptr_t)(stacks[stacks_used - 1] + STACK_BYTES), entry, arg, tls, thread_class,
	    thread));
}

static int
create(void (*entry)(uint64_t), uint64_t arg, uint64_t tls, uint64_t *thread)
{
	return (create_class(entry, arg, tls, ERX_THREAD_CLASS_WORKER, thread));
}

static bool
spawn(void (*entry)(uint64_t), uint64_t arg, uint64_t tls)
{
	uint64_t thread;

	return (create(entry, arg, tls, &thread) == ERX_OK && erx_thread_start(thread) == ERX_OK);
}

static void
tls_helper(uint64_t arg)
{
	char here;

	seen_arg = arg;
	seen_tls = erx_fiasco_thread_pointer();
	seen_stack = (uint64_t)(uintptr_t)&here;
	bump_done();
	park();
}

static bool
case_tls_and_arg(void)
{
	const uint8_t *stack;

	atomic_store(&done, 0);
	if (!spawn(tls_helper, ARG_VALUE, TLS_VALUE) || !wait_for(&done, 1))
		return (false);
	stack = stacks[stacks_used - 1];
	return (seen_tls == TLS_VALUE && seen_arg == ARG_VALUE &&
	    seen_stack >= (uint64_t)(uintptr_t)stack && seen_stack < (uint64_t)(uintptr_t)(stack + STACK_BYTES));
}

static void
idle_helper(uint64_t arg)
{
	(void)arg;
	bump_done();
	park();
}

static bool
case_double_start_refused(void)
{
	uint64_t thread;

	atomic_store(&done, 0);
	if (create(idle_helper, 0, 0, &thread) != ERX_OK || erx_thread_start(thread) != ERX_OK ||
	    !wait_for(&done, 1))
		return (false);
	return (erx_thread_start(thread) == ERX_EINVAL);
}

static bool
case_bad_handle_refused(void)
{
	return (erx_thread_start(77) == ERX_EINVAL && erx_thread_start(UINT64_C(1) << 40) == ERX_EINVAL &&
	    erx_thread_start(0) == ERX_EINVAL && erx_fiasco_thread_set_clear_word(77, 0) == ERX_EINVAL &&
	    erx_fiasco_thread_set_clear_word(ERX_FIASCO_THREADS_MAX, 0) == ERX_EINVAL);
}

/* Malformed requests through the real gate: none of them may reach a body. */
static bool
case_wire_refusals(void)
{
	const uint64_t self = erx_fiasco_thread_self()->index;
	const erx_fiasco_thread_start_request_t good = { .caller = self, .thread = 77 };
	const erx_fiasco_thread_start_request_t bad_caller = { .caller = ERX_FIASCO_THREADS_MAX, .thread = 77 };
	erx_fiasco_reply_t reply;

	return (erx_fiasco_service_call(200, &good, sizeof(good), &reply) == ERX_EINVAL &&
	    erx_fiasco_service_call(ERX_FIASCO_CALL_THREAD_START, &good, sizeof(uint64_t), &reply) == ERX_EINVAL &&
	    erx_fiasco_service_call(ERX_FIASCO_CALL_THREAD_START, &bad_caller, sizeof(bad_caller), &reply) == ERX_EINVAL &&
	    erx_fiasco_service_call(ERX_CALL_DEBUG_LOG, &good, sizeof(good), &reply) == ERX_ENOTSUP &&
	    erx_fiasco_service_call(ERX_FIASCO_CALL_THREAD_START, &good, sizeof(good), &reply) == ERX_EINVAL);
}

static bool
case_umtx_word_differs(void)
{
	static _Atomic uint32_t word = 1;

	return (erx_umtx_wait(word_addr(&word), 0, ERX_FIASCO_UMTX_FOREVER) == ERX_OK);
}

static bool
case_umtx_past_deadline(void)
{
	static _Atomic uint32_t word;

	return (erx_umtx_wait(word_addr(&word), 0, erx_fiasco_clock_ns() - 1) == ERX_ETIMEDOUT);
}

/* A timed wait returns no sooner than its deadline, at several lengths. */
static bool
case_umtx_timeout_not_early(void)
{
	static const uint64_t lengths_ns[] = { 1000, 1500000, 20 * NS_PER_MS, 100 * NS_PER_MS };
	static _Atomic uint32_t word;

	for (size_t index = 0; index < sizeof(lengths_ns) / sizeof(lengths_ns[0]); index++) {
		const uint64_t deadline = erx_fiasco_clock_ns() + lengths_ns[index];

		if (erx_umtx_wait(word_addr(&word), 0, deadline) != ERX_ETIMEDOUT ||
		    erx_fiasco_clock_ns() < deadline)
			return (false);
	}
	return (true);
}

static void
order_helper(uint64_t arg)
{
	atomic_fetch_add_explicit(&ready, 1, memory_order_release);
	(void)erx_umtx_wake(word_addr(&ready), 128);
	while (atomic_load_explicit(&gate_word, memory_order_acquire) == 0)
		(void)erx_umtx_wait(word_addr(&gate_word), 0, ERX_FIASCO_UMTX_FOREVER);
	atomic_store_explicit(&order[atomic_fetch_add_explicit(&order_next, 1, memory_order_acq_rel)],
	    (uint32_t)arg, memory_order_release);
	bump_done();
	park();
}

/* Sleep without the word under test: a deadline on a word nobody wakes. */
static void
settle(uint64_t length_ns)
{
	static _Atomic uint32_t word;

	(void)erx_umtx_wait(word_addr(&word), 0, erx_fiasco_clock_ns() + length_ns);
}

/* Each wake of one takes the oldest waiter, and a wake with none reports none. */
static bool
case_umtx_wake_in_order(void)
{
	atomic_store(&done, 0);
	atomic_store(&ready, 0);
	for (uint32_t waiter = 1; waiter <= 3; waiter++) {
		if (!spawn(order_helper, waiter, 0) || !wait_for(&ready, waiter))
			return (false);
		settle(QUEUE_SETTLE_NS);
	}
	atomic_store_explicit(&gate_word, 1, memory_order_release);
	for (uint32_t waiter = 1; waiter <= 3; waiter++) {
		if (erx_umtx_wake(word_addr(&gate_word), 1) != 1 || !wait_for(&done, waiter) ||
		    atomic_load_explicit(&order[waiter - 1], memory_order_acquire) != waiter)
			return (false);
	}
	return (erx_umtx_wake(word_addr(&gate_word), 1) == 0);
}

static void
ping_helper(uint64_t arg)
{
	(void)arg;
	for (uint32_t round = 0; round < PING_ROUNDS; round++) {
		if (!wait_for(&turn, 1))
			break;
		atomic_store_explicit(&turn, 0, memory_order_release);
		(void)erx_umtx_wake(word_addr(&turn), 1);
	}
	bump_done();
	park();
}

/* Turn by turn: one lost wake and the pair stops until the patience runs out. */
static bool
case_umtx_ping_pong(void)
{
	atomic_store(&done, 0);
	atomic_store(&turn, 0);
	if (!spawn(ping_helper, 0, 0))
		return (false);
	for (uint32_t round = 0; round < PING_ROUNDS; round++) {
		atomic_store_explicit(&turn, 1, memory_order_release);
		(void)erx_umtx_wake(word_addr(&turn), 1);
		if (!wait_for(&turn, 0))
			return (false);
	}
	return (wait_for(&done, 1));
}

/*
 * Waits with deadlines as short as the wakes come, then one with no waker at all:
 * a semaphore left holding an up would make that one return woken.
 */
static void
race_helper(uint64_t arg)
{
	static _Atomic uint32_t quiet;

	(void)arg;
	for (uint32_t round = 0; round < RACE_ROUNDS; round++)
		(void)erx_umtx_wait(word_addr(&race_word), 0, erx_fiasco_clock_ns() + (round % 8 + 1) * 10000);
	atomic_store_explicit(&race_stop, 1, memory_order_release);
	/* A waker may still have taken the last wait; its up was absorbed in that wait. */
	if (erx_umtx_wait(word_addr(&quiet), 0, erx_fiasco_clock_ns() + 5 * NS_PER_MS) != ERX_ETIMEDOUT)
		atomic_store_explicit(&race_stale, 1, memory_order_release);
	bump_done();
	park();
}

static bool
case_umtx_timeout_races_wake(void)
{
	atomic_store(&done, 0);
	atomic_store(&race_stop, 0);
	if (!spawn(race_helper, 0, 0))
		return (false);
	while (atomic_load_explicit(&race_stop, memory_order_acquire) == 0)
		(void)erx_umtx_wake(word_addr(&race_word), 1);
	return (wait_for(&done, 1) && atomic_load(&race_stale) == 0);
}

/*
 * How the suite's waits came out: an absorbed wait is a timeout that met a wake, so
 * a run at four CPUs that shows some has crossed the race. A wait that returned with
 * its node still queued was woken by no taker, and none should be.
 */
static bool
case_umtx_no_stale_wake(void)
{
	say("erx: threads: waits woken ");
	say_number(atomic_load(&erx_fiasco_test_umtx_woken));
	say(" timed out ");
	say_number(atomic_load(&erx_fiasco_test_umtx_timed_out));
	say(" absorbed ");
	say_number(atomic_load(&erx_fiasco_test_umtx_absorbed));
	say(" stale ");
	say_number(atomic_load(&erx_fiasco_test_umtx_stale));
	say("\n");
	return (atomic_load(&erx_fiasco_test_umtx_stale) == 0);
}

static void
memory_helper(uint64_t arg)
{
	uint64_t base;

	(void)arg;
	for (uint32_t round = 0; round < 100; round++) {
		if (erx_vm_reserve(0, ERX_PAGE_SIZE, 0, &base) != ERX_OK ||
		    erx_vm_commit(base, ERX_PAGE_SIZE) != ERX_OK) {
			atomic_store(&memory_failed, 1);
			break;
		}
		*(volatile uint64_t *)(uintptr_t)base = base;
		if (*(volatile uint64_t *)(uintptr_t)base != base || erx_vm_release(base, ERX_PAGE_SIZE) != ERX_OK) {
			atomic_store(&memory_failed, 1);
			break;
		}
	}
	bump_done();
	park();
}

/* Two threads call the memory service at once; only the service touches its table. */
static bool
case_memory_from_threads(void)
{
	const uint64_t before = erx_fiasco_vm_free_pages();

	atomic_store(&done, 0);
	if (!spawn(memory_helper, 0, 0) || !spawn(memory_helper, 0, 0) || !wait_for(&done, 2))
		return (false);
	return (atomic_load(&memory_failed) == 0 && erx_fiasco_vm_free_pages() == before);
}

static _Atomic uint32_t failed_start_ran;

static void
never_helper(uint64_t arg)
{
	(void)arg;
	atomic_store(&failed_start_ran, 1);
	park();
}

static bool
stack_untouched(const uint8_t *stack)
{
	for (size_t offset = 0; offset < STACK_BYTES; offset++)
		if (stack[offset] != 0)
			return (false);
	return (true);
}

/*
 * Each step of a start fails in turn: the status returns, both capabilities are
 * gone, the thread never ran on its stack, and the next thread starts.
 */
static bool
case_failed_start(void)
{
	for (uint32_t step = 1; step <= START_STEPS; step++) {
		const uint8_t *stack;
		uint64_t thread;
		int status;

		if (create(never_helper, step, 0, &thread) != ERX_OK)
			return (false);
		stack = stacks[stacks_used - 1];
		atomic_store(&erx_fiasco_test_start_fails, step);
		status = erx_thread_start(thread);
		atomic_store(&erx_fiasco_test_start_fails, 0);
		if (status != ERX_ENOMEM || !erx_fiasco_test_thread_caps_gone((uint32_t)thread) ||
		    !stack_untouched(stack))
			return (false);
		atomic_store(&done, 0);
		if (!spawn(idle_helper, step, step) || !wait_for(&done, 1))
			return (false);
	}
	return (atomic_load(&failed_start_ran) == 0);
}

/* What a hog's run saw of each CPU's probe. */
static _Atomic uint64_t probe_count[CPUS_MAX];
static _Atomic uint32_t probe_stop;
static uint64_t hog_delta[CPUS_MAX];
static _Atomic uint32_t hog_done;
static _Alignas(16) uint8_t hog_stacks[CPUS_MAX * HOG_TRIES][STACK_BYTES];

static void
probe_helper(uint64_t cpu)
{
	while (atomic_load_explicit(&probe_stop, memory_order_acquire) == 0)
		atomic_fetch_add_explicit(&probe_count[cpu], 1, memory_order_relaxed);
	bump_done();
	erx_thread_exit();
}

/*
 * Above every other thread of its CPU and nothing else: while it spins, that CPU's
 * probe cannot run, and every other CPU's can.
 */
static void
hog_helper(uint64_t cpu)
{
	uint64_t before[CPUS_MAX], deadline;

	if (erx_fiasco_test_thread_priority(erx_fiasco_thread_self()->index, HOG_PRIORITY, UINT64_C(1) << cpu) != ERX_OK)
		atomic_store(&probe_stop, 1);
	deadline = erx_fiasco_clock_ns() + HOG_NS;
	for (uint32_t index = 0; index < cpu_count; index++)
		before[index] = atomic_load_explicit(&probe_count[index], memory_order_relaxed);
	while (erx_fiasco_clock_ns() < deadline)
		continue;
	for (uint32_t index = 0; index < cpu_count; index++)
		hog_delta[index] = atomic_load_explicit(&probe_count[index], memory_order_relaxed) - before[index];
	/* Back beneath no one: what follows takes locks a thread of this CPU may hold. */
	(void)erx_fiasco_test_thread_priority(erx_fiasco_thread_self()->index, NORMAL_PRIORITY, UINT64_C(1) << cpu);
	atomic_store_explicit(&hog_done, 1, memory_order_release);
	(void)erx_umtx_wake(word_addr(&hog_done), 1);
	erx_thread_exit();
}

/* One hog on this CPU. A vCPU the host starved shows no count, so the rest get retries. */
static bool
affinity_shows(uint32_t cpu)
{
	for (uint32_t attempt = 0; attempt < HOG_TRIES; attempt++) {
		uint64_t hog;
		uint32_t moved = 0;

		atomic_store(&hog_done, 0);
		if (create_on((uint64_t)(uintptr_t)(hog_stacks[cpu * HOG_TRIES + attempt] + STACK_BYTES), hog_helper, cpu, 0,
		    ERX_THREAD_CLASS_WORKER, &hog) != ERX_OK || erx_thread_set_affinity(hog, UINT64_C(1) << cpu) != ERX_OK ||
		    erx_thread_start(hog) != ERX_OK || !wait_for(&hog_done, 1))
			return (false);
		if (hog_delta[cpu] != 0)
			return (false);
		for (uint32_t index = 0; index < cpu_count; index++)
			moved += hog_delta[index] != 0;
		if (moved == cpu_count - 1)
			return (true);
	}
	return (false);
}

/* Affinity to each CPU, read back through what only a thread on that CPU can stop. */
static bool
case_affinity_each_cpu(void)
{
	bool ok = true;

	if (cpu_count > CPUS_MAX)
		return (false);
	atomic_store(&done, 0);
	atomic_store(&probe_stop, 0);
	for (uint32_t cpu = 0; cpu < cpu_count; cpu++) {
		uint64_t probe;

		if (create(probe_helper, cpu, 0, &probe) != ERX_OK ||
		    erx_thread_set_affinity(probe, UINT64_C(1) << cpu) != ERX_OK || erx_thread_start(probe) != ERX_OK)
			return (false);
	}
	for (uint32_t cpu = 0; cpu < cpu_count && ok; cpu++)
		ok = affinity_shows(cpu);
	atomic_store_explicit(&probe_stop, 1, memory_order_release);
	return (wait_for(&done, cpu_count) && ok);
}

static bool
case_affinity_refused(void)
{
	uint64_t thread;
	bool ok;

	atomic_store(&done, 0);
	if (create(idle_helper, 0, 0, &thread) != ERX_OK)
		return (false);
	ok = erx_thread_set_affinity(thread, 0) == ERX_EINVAL && erx_thread_set_affinity(thread, UINT64_C(1) << 63) == ERX_EINVAL &&
	    erx_thread_set_affinity(ERX_FIASCO_THREADS_MAX, 1) == ERX_EINVAL && erx_thread_set_affinity(77, 1) == ERX_EINVAL;
	/* The refusals left the mask the create's helper set. */
	return (ok && erx_thread_start(thread) == ERX_OK && wait_for(&done, 1));
}

static _Atomic uint32_t join_word;
static _Atomic uint64_t join_seen;
static _Alignas(16) uint8_t join_stack[STACK_BYTES];

static void
join_helper(uint64_t arg)
{
	atomic_store_explicit(&join_seen, arg, memory_order_release);
	erx_thread_exit();
}

static bool
join_refused(const char *why, uint32_t round)
{
	say("erx: threads: join: ");
	say(why);
	say(" in round ");
	say_number(round);
	say("\n");
	return (false);
}

/*
 * musl's join, without musl: the word holds a nonzero identifier until the reaper
 * clears it, and a thread reuses the same stack as soon as it does. The joined
 * handle names no thread, and in this many rounds every index comes back.
 */
static bool
case_join_loop(void)
{
	static uint8_t seen_index[ERX_FIASCO_THREADS_MAX];
	uint32_t reused = 0;

	for (uint32_t round = 0; round < JOIN_ROUNDS; round++) {
		const uint64_t patience = erx_fiasco_clock_ns() + PATIENCE_NS;
		uint64_t thread;
		int status;

		atomic_store_explicit(&join_word, 1, memory_order_release);
		/* Every free index may wait for the kernel's write of its marker. */
		while ((status = create_on((uint64_t)(uintptr_t)(join_stack + STACK_BYTES), join_helper, round, 0,
		    ERX_THREAD_CLASS_WORKER, &thread)) == ERX_ENOMEM && erx_fiasco_clock_ns() < patience)
			settle(NS_PER_MS);
		if (status != ERX_OK)
			return (join_refused("no thread", round));
		if (erx_fiasco_thread_set_clear_word(thread, word_addr(&join_word)) != ERX_OK)
			return (join_refused("no word to clear", round));
		if (erx_thread_start(thread) != ERX_OK)
			return (join_refused("no start", round));
		if (!wait_for(&join_word, 0))
			return (join_refused("the word stayed set", round));
		if (atomic_load_explicit(&join_seen, memory_order_acquire) != round)
			return (join_refused("another round's value", round));
		if (!erx_fiasco_test_thread_caps_gone((uint32_t)thread))
			return (join_refused("a live capability", round));
		if (erx_thread_start(thread) != ERX_EINVAL)
			return (join_refused("a start of the joined handle", round));
		if (seen_index[thread] != 0)
			reused++;
		seen_index[thread] = 1;
	}
	say("erx: threads: join rounds reusing an index ");
	say_number(reused);
	say("\n");
	return (reused != 0);
}

static _Atomic uint32_t detached_ran;

static void
detached_helper(uint64_t base)
{
	atomic_fetch_add_explicit(&detached_ran, 1, memory_order_release);
	(void)erx_umtx_wake(word_addr(&detached_ran), 1);
	erx_thread_exit_release(base, DETACHED_PAGES * ERX_PAGE_SIZE);
}

/* The reaper releases each stack, so the pool's count comes back, with no join to wait on. */
static bool
case_detached_loop(void)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	const uint64_t deadline = erx_fiasco_clock_ns() + PATIENCE_NS;
	const uint64_t bytes = DETACHED_PAGES * ERX_PAGE_SIZE;

	atomic_store(&detached_ran, 0);
	for (uint32_t round = 0; round < DETACHED_ROUNDS; round++) {
		uint64_t base, thread;
		int status;

		if (erx_vm_reserve(0, bytes, 0, &base) != ERX_OK || erx_vm_commit(base, bytes) != ERX_OK)
			return (false);
		while ((status = create_on(base + bytes, detached_helper, base, 0, ERX_THREAD_CLASS_WORKER, &thread)) == ERX_ENOMEM &&
		    erx_fiasco_clock_ns() < deadline)
			settle(NS_PER_MS);
		if (status != ERX_OK || erx_thread_start(thread) != ERX_OK || !wait_for(&detached_ran, round + 1))
			return (false);
	}
	while (erx_fiasco_vm_free_pages() != before) {
		if (erx_fiasco_clock_ns() >= deadline)
			return (false);
		settle(NS_PER_MS);
	}
	return (true);
}

static bool
case_park_refusals(void)
{
	return (erx_park(0, 0, ERX_FIASCO_UMTX_FOREVER) == ERX_ETYPE && erx_executor_wake(ERX_GROUP_EXECUTORS_MAX) == ERX_EINVAL &&
	    erx_executor_wake(ERX_GROUP_EXECUTORS_MAX - 1) == ERX_EINVAL);
}

static _Atomic uint32_t park_self_ok;

static uint64_t
group_epoch(void)
{
	return (atomic_load_explicit(&erx_fiasco_group_status()->epoch, memory_order_acquire));
}

static uint64_t
slot_epoch(uint32_t slot)
{
	return (atomic_load_explicit(&erx_fiasco_group_status()->exec[slot].epoch, memory_order_acquire));
}

/* An executor alone: either epoch moved since the read returns at once, and a quiet park times out. */
static void
park_self_helper(uint64_t arg)
{
	const uint32_t slot = erx_fiasco_thread_self()->executor_slot;
	uint64_t group = group_epoch(), epoch = slot_epoch(slot), deadline;
	bool ok;

	(void)arg;
	erx_fiasco_group_trigger();
	ok = erx_park(group, epoch, ERX_FIASCO_UMTX_FOREVER) == ERX_OK;
	group = group_epoch();
	ok = ok && erx_executor_wake(slot) == ERX_OK;
	ok = ok && erx_park(group, epoch, ERX_FIASCO_UMTX_FOREVER) == ERX_OK;
	group = group_epoch();
	epoch = slot_epoch(slot);
	deadline = erx_fiasco_clock_ns() + 20 * NS_PER_MS;
	ok = ok && erx_park(group, epoch, deadline) == ERX_ETIMEDOUT && erx_fiasco_clock_ns() >= deadline;
	ok = ok && atomic_load(&erx_fiasco_group_status()->parked) == 0;
	atomic_store(&park_self_ok, ok ? 1 : 0);
	bump_done();
	erx_thread_exit();
}

static bool
case_park_alone(void)
{
	uint64_t thread;

	atomic_store(&done, 0);
	if (create_class(park_self_helper, 0, 0, ERX_THREAD_CLASS_EXECUTOR, &thread) != ERX_OK ||
	    erx_thread_start(thread) != ERX_OK || !wait_for(&done, 1))
		return (false);
	return (atomic_load(&park_self_ok) == 1);
}

static _Atomic uint32_t park_gate_at;
static _Atomic uint32_t park_gate_open;
static _Atomic uint32_t park_gate_ok;

/* The window the protocol exists for: the trigger lands between the empty check and the park. */
static void
park_gate_helper(uint64_t arg)
{
	const uint32_t slot = erx_fiasco_thread_self()->executor_slot;
	const uint64_t group = group_epoch(), epoch = slot_epoch(slot);

	(void)arg;
	atomic_store_explicit(&park_gate_at, 1, memory_order_release);
	(void)erx_umtx_wake(word_addr(&park_gate_at), 1);
	if (wait_for(&park_gate_open, 1))
		atomic_store(&park_gate_ok, erx_park(group, epoch, ERX_FIASCO_UMTX_FOREVER) == ERX_OK ? 1 : 0);
	bump_done();
	erx_thread_exit();
}

static bool
case_park_trigger_in_window(void)
{
	uint64_t thread;

	atomic_store(&done, 0);
	if (create_class(park_gate_helper, 0, 0, ERX_THREAD_CLASS_EXECUTOR, &thread) != ERX_OK ||
	    erx_thread_start(thread) != ERX_OK || !wait_for(&park_gate_at, 1))
		return (false);
	erx_fiasco_group_trigger();
	atomic_store_explicit(&park_gate_open, 1, memory_order_release);
	(void)erx_umtx_wake(word_addr(&park_gate_open), 1);
	return (wait_for(&done, 1) && atomic_load(&park_gate_ok) == 1);
}

static _Atomic uint32_t park_published;
static _Atomic uint32_t park_consumed;
static _Atomic uint32_t park_stop;

/* The runtime's loop: epochs, then work, then the park. Its deadline only reports a lost wake. */
static void
park_worker_helper(uint64_t arg)
{
	const uint32_t slot = erx_fiasco_thread_self()->executor_slot;

	(void)arg;
	while (atomic_load_explicit(&park_stop, memory_order_acquire) == 0) {
		const uint64_t group = group_epoch(), epoch = slot_epoch(slot);
		uint32_t consumed = atomic_load_explicit(&park_consumed, memory_order_acquire);

		if (consumed < atomic_load_explicit(&park_published, memory_order_acquire)) {
			if (atomic_compare_exchange_strong_explicit(&park_consumed, &consumed, consumed + 1,
			    memory_order_acq_rel, memory_order_acquire))
				(void)erx_umtx_wake(word_addr(&park_consumed), 1);
			continue;
		}
		(void)erx_park(group, epoch, ERX_FIASCO_UMTX_FOREVER);
	}
	bump_done();
	erx_thread_exit();
}

/* Two executors on two CPUs and a trigger per round: one lost wake stops the turn. */
static bool
case_park_ping(void)
{
	atomic_store(&done, 0);
	for (uint32_t index = 0; index < PARK_EXECUTORS; index++) {
		uint64_t thread;

		if (create_class(park_worker_helper, index, 0, ERX_THREAD_CLASS_EXECUTOR, &thread) != ERX_OK ||
		    erx_thread_start(thread) != ERX_OK)
			return (false);
	}
	for (uint32_t round = 1; round <= PARK_ROUNDS; round++) {
		atomic_store_explicit(&park_published, round, memory_order_release);
		erx_fiasco_group_trigger();
		if (!wait_for(&park_consumed, round))
			return (false);
	}
	atomic_store_explicit(&park_stop, 1, memory_order_release);
	for (uint32_t index = 0; index < PARK_EXECUTORS; index++)
		erx_fiasco_group_trigger();
	return (wait_for(&done, PARK_EXECUTORS));
}

static _Atomic uint32_t park_race_stop;
static _Atomic uint32_t park_race_slot;
static _Atomic uint32_t park_race_stale;
static _Atomic uint32_t park_race_left;

/*
 * Parks with deadlines as short as the wakes come, then one with no waker: a
 * semaphore left holding an up would return it woken.
 */
static void
park_race_helper(uint64_t arg)
{
	const uint32_t slot = erx_fiasco_thread_self()->executor_slot;

	(void)arg;
	atomic_store_explicit(&park_race_slot, slot + 1, memory_order_release);
	for (uint32_t round = 0; round < RACE_ROUNDS; round++)
		(void)erx_park(group_epoch(), slot_epoch(slot), erx_fiasco_clock_ns() + (round % 8 + 1) * 10000);
	atomic_store_explicit(&park_race_stop, 1, memory_order_release);
	/* The waker's last wake has returned before this thread looks at its epochs. */
	while (atomic_load_explicit(&park_race_left, memory_order_acquire) == 0)
		settle(NS_PER_MS);
	if (erx_park(group_epoch(), slot_epoch(slot), erx_fiasco_clock_ns() + 5 * NS_PER_MS) != ERX_ETIMEDOUT)
		atomic_store_explicit(&park_race_stale, 1, memory_order_release);
	bump_done();
	erx_thread_exit();
}

static bool
case_park_timeout_races_wake(void)
{
	uint64_t thread;
	uint32_t slot;

	atomic_store(&done, 0);
	if (create_class(park_race_helper, 0, 0, ERX_THREAD_CLASS_EXECUTOR, &thread) != ERX_OK ||
	    erx_thread_start(thread) != ERX_OK)
		return (false);
	while ((slot = atomic_load_explicit(&park_race_slot, memory_order_acquire)) == 0)
		settle(NS_PER_MS);
	while (atomic_load_explicit(&park_race_stop, memory_order_acquire) == 0)
		(void)erx_executor_wake(slot - 1);
	atomic_store_explicit(&park_race_left, 1, memory_order_release);
	return (wait_for(&done, 1) && atomic_load(&park_race_stale) == 0);
}

static bool
case_many_threads(void)
{
	atomic_store(&done, 0);
	for (uint32_t index = 0; index < MANY_THREADS; index++)
		if (!spawn(idle_helper, index, index))
			return (false);
	return (wait_for(&done, MANY_THREADS));
}

static _Atomic uint32_t finish_word;

/*
 * Ends the run once the first thread has exited: its capabilities are gone, and
 * this thread still reaches the service. Started before the indices run out.
 */
static void
finisher(uint64_t arg)
{
	(void)arg;
	(void)wait_for(&finish_word, 1);
	while (!erx_fiasco_test_thread_caps_gone(0))
		settle(NS_PER_MS);
	report("first_thread_exit", true);
	say("erx: threads: done\n");
	(void)erx_machine_end(0, ERX_END_OFF);
	say("erx: threads: machine end refused FAILED\n");
	erx_fiasco_sleep_forever();
}

/*
 * The table's last indices never start: no free one is ERX_ENOMEM. The first thread,
 * the reaper, the finisher and the parked helpers hold the rest, and an index that
 * failed a start or was just reaped may stay held for as long as Fiasco has not
 * written its marker.
 */
static bool
case_indices_run_out(void)
{
	erx_utcb_t *const utcb = erx_utcb_self();
	uint64_t thread;
	int status;
	uint32_t made = 0;

	for (size_t word = 0; word < sizeof(erx_fiasco_start_t) / sizeof(uint64_t); word++)
		atomic_store_explicit(&utcb->mr[word], 0, memory_order_relaxed);
	while ((status = erx_thread_create(0, 0, 0, 0, &thread)) == ERX_OK && made < ERX_FIASCO_THREADS_MAX)
		made++;
	return (status == ERX_ENOMEM && made + MANY_THREADS + 15 <= ERX_FIASCO_THREADS_MAX);
}

void
erx_fiasco_root_main(void)
{
	const char *reason = erx_fiasco_root_up(NULL, 0);

	if (reason != NULL) {
		say(reason);
		erx_fiasco_machine_off();
	}
	say("erx: threads: service up\n");
	cpu_count = erx_fiasco_test_cpu_count();
	say("erx: threads: cpus ");
	say_number(cpu_count);
	say("\n");
	report("tls_and_arg", case_tls_and_arg());
	report("double_start_refused", case_double_start_refused());
	report("bad_handle_refused", case_bad_handle_refused());
	report("wire_refusals", case_wire_refusals());
	report("umtx_word_differs", case_umtx_word_differs());
	report("umtx_past_deadline", case_umtx_past_deadline());
	report("umtx_timeout_not_early", case_umtx_timeout_not_early());
	report("umtx_wake_in_order", case_umtx_wake_in_order());
	report("umtx_ping_pong", case_umtx_ping_pong());
	report("umtx_timeout_races_wake", case_umtx_timeout_races_wake());
	report("umtx_no_stale_wake", case_umtx_no_stale_wake());
	report("memory_from_threads", case_memory_from_threads());
	report("failed_start", case_failed_start());
	report("affinity_each_cpu", case_affinity_each_cpu());
	report("affinity_refused", case_affinity_refused());
	report("join_loop", case_join_loop());
	report("detached_loop", case_detached_loop());
	report("park_refusals", case_park_refusals());
	report("park_alone", case_park_alone());
	report("park_trigger_in_window", case_park_trigger_in_window());
	report("park_ping", case_park_ping());
	report("park_timeout_races_wake", case_park_timeout_races_wake());
	report("umtx_no_stale_wake_after", case_umtx_no_stale_wake());
	report("many_threads", case_many_threads());
	{
		uint64_t thread;

		if (create(finisher, 0, 0, &thread) != ERX_OK || erx_thread_start(thread) != ERX_OK)
			say("erx: threads: finisher FAILED\n");
	}
	report("indices_run_out", case_indices_run_out());
	atomic_store_explicit(&finish_word, 1, memory_order_release);
	(void)erx_umtx_wake(word_addr(&finish_word), 1);
	erx_thread_exit();
}
