/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The threads transcript: a root task that creates and starts threads through the
 * service and waits on words, and reports each case on one line, which
 * tools/lib/erx/native_threads.rb judges. Threads never exit here, so each case's
 * threads park on a word that never changes, and the
 * last case uses up what indices remain.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/umtx.h"
#include "liberx/backend/fiasco/vm.h"

#define STACKS		56u
#define STACK_BYTES	16384u
#define MANY_THREADS	32u
#define START_STEPS	3u
#define PING_ROUNDS	2000u
#define RACE_ROUNDS	200u
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

static int
create(void (*entry)(uint64_t), uint64_t arg, uint64_t tls, uint64_t *thread)
{
	erx_fiasco_start_t start = { 0 };
	const uint64_t *const words = (const uint64_t *)(const void *)&start;
	erx_utcb_t *const utcb = erx_utcb_self();

	if (stacks_used >= STACKS)
		return (ERX_ENOMEM);
	start.regs.gpr[0] = arg;
	start.regs.sp = (uint64_t)(uintptr_t)(stacks[stacks_used] + STACK_BYTES);
	start.regs.pc = (uint64_t)(uintptr_t)entry;
	start.tls = tls;
	stacks_used++;
	for (size_t word = 0; word < sizeof(start) / sizeof(uint64_t); word++)
		atomic_store_explicit(&utcb->mr[word], words[word], memory_order_relaxed);
	return (erx_thread_create(0, 0, 0, 0, thread));
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
	    erx_thread_start(0) == ERX_EINVAL);
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

static bool
case_many_threads(void)
{
	atomic_store(&done, 0);
	for (uint32_t index = 0; index < MANY_THREADS; index++)
		if (!spawn(idle_helper, index, index))
			return (false);
	return (wait_for(&done, MANY_THREADS));
}

/*
 * The table's last indices never start: no free one is ERX_ENOMEM. The first thread
 * and the twelve helpers before the many hold the rest, and each failed start may
 * hold its index too, for as long as Fiasco has not written its marker.
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
	return (status == ERX_ENOMEM && made + MANY_THREADS + 13 <= ERX_FIASCO_THREADS_MAX &&
	    made + MANY_THREADS + 13 + START_STEPS >= ERX_FIASCO_THREADS_MAX);
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
	report("memory_from_threads", case_memory_from_threads());
	report("failed_start", case_failed_start());
	report("many_threads", case_many_threads());
	report("indices_run_out", case_indices_run_out());
	say("erx: threads: done\n");
	(void)erx_machine_end(0, ERX_END_OFF);
	say("erx: threads: machine end refused FAILED\n");
	erx_fiasco_sleep_forever();
}
