/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * An up across CPUs racing a down's timeout, on the test kernel whose up pauses
 * between dequeuing its waiter and activating it (tools/lib/erx/native_semaphore_race.rb).
 * The waiter's first down times out meanwhile and must report the up. The activation
 * must then reach nothing the waiter does next: neither an IPC receive wait, which it
 * would end early, nor another down, which it would complete with no up and with the
 * waiter still queued. A round counts only if its first down outlasted its timer and
 * still took the up, and the up took the kernel's whole hold; too few such rounds is a
 * failure of its own, since nothing was then tested.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/thread.h"

#define NS_PER_US	UINT64_C(1000)
#define NS_PER_MS	UINT64_C(1000000)
#define STACK_BYTES	16384u
/* The up comes while the down waits, and the down's timer fires inside the kernel's hold. */
#define UP_AFTER_NS	(UINT64_C(10) * NS_PER_MS)
#define FIRST_DOWN_NS	(UINT64_C(100) * NS_PER_MS)
/* Longer than the hold, so a late activation lands inside. */
#define SLEEP_NS	(UINT64_C(1500) * NS_PER_MS)
#define SECOND_DOWN_NS	(UINT64_C(1500) * NS_PER_MS)
#define DRAIN_NS	(UINT64_C(30000) * NS_PER_MS)
#define PATIENCE_NS	(UINT64_C(60000) * NS_PER_MS)
#define HOLD_NS		((uint64_t)ERX_TEST_SEMAPHORE_WAKE_HOLD_US * NS_PER_US)
#define RACED_WANTED	3u
#define TRIES		30u

_Static_assert(FIRST_DOWN_NS < HOLD_NS && SLEEP_NS > HOLD_NS && SECOND_DOWN_NS > HOLD_NS,
    "the timer fires inside the hold, and what follows outlasts it");

typedef enum {
	WAITER_SLEEPS = 1,	/* after the raced down, an IPC receive wait */
	WAITER_DOWNS		/* after the raced down, another down with no up */
} waiter_next_t;

static _Alignas(16) uint8_t waiter_stack[STACK_BYTES];
static uint64_t waiter_semaphore;
static _Atomic uint32_t round_next;	/* the round the first thread asks for */
static _Atomic uint32_t round_armed;	/* the round whose down the waiter is entering */
static _Atomic uint32_t round_done;	/* the round the waiter has finished */
static _Atomic uint32_t next_step;	/* a waiter_next_t */
static _Atomic uint32_t raced;		/* rounds whose first down was raced */
static _Atomic uint32_t damaged;	/* rounds in which the activation reached what came next */

void erx_fiasco_root_main(void);

static void
say(const char *text)
{
	size_t length = 0;

	while (text[length] != '\0')
		length++;
	erx_fiasco_console_write(text, length);
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

/* One round's next step, once its first down reported the up with the timer already past. */
static void
waiter_after_raced_down(void)
{
	const uint64_t start = erx_fiasco_clock_ns();

	atomic_fetch_add_explicit(&raced, 1, memory_order_relaxed);
	if (atomic_load_explicit(&next_step, memory_order_relaxed) == WAITER_SLEEPS) {
		erx_fiasco_test_ipc_sleep_us(SLEEP_NS / NS_PER_US);
		if (erx_fiasco_clock_ns() - start < SLEEP_NS)
			atomic_fetch_add_explicit(&damaged, 1, memory_order_relaxed);
	} else if (erx_fiasco_semaphore_down(waiter_semaphore, start + SECOND_DOWN_NS)) {
		atomic_fetch_add_explicit(&damaged, 1, memory_order_relaxed);
	}
}

static _Noreturn void
waiter(uint64_t unused)
{
	uint32_t round = 0;

	(void)unused;
	waiter_semaphore = erx_fiasco_thread_self()->semaphore;
	atomic_store_explicit(&round_done, 0, memory_order_release);
	for (;;) {
		uint64_t start;
		bool got;

		while (atomic_load_explicit(&round_next, memory_order_acquire) == round)
			;
		round++;
		atomic_store_explicit(&round_armed, round, memory_order_release);
		start = erx_fiasco_clock_ns();
		got = erx_fiasco_semaphore_down(waiter_semaphore, start + FIRST_DOWN_NS);
		if (!got)
			/* The up came after the timeout: it is counted, so it is there to take. */
			(void)erx_fiasco_semaphore_down(waiter_semaphore, erx_fiasco_clock_ns() + DRAIN_NS);
		else if (erx_fiasco_clock_ns() - start >= FIRST_DOWN_NS)
			waiter_after_raced_down();
		atomic_store_explicit(&round_done, round, memory_order_release);
	}
}

static bool
wait_for_word(_Atomic uint32_t *word, uint32_t want)
{
	const uint64_t stop = erx_fiasco_clock_ns() + PATIENCE_NS;

	while (atomic_load_explicit(word, memory_order_acquire) != want)
		if (erx_fiasco_clock_ns() >= stop)
			return (false);
	return (true);
}

/* Rounds until enough were raced. True only with enough raced rounds and none damaged. */
static bool
run_case(const char *name, waiter_next_t step, uint32_t *round)
{
	uint64_t up_at, up_took;
	uint32_t raced_before;
	bool responded = true;

	atomic_store(&raced, 0);
	atomic_store(&damaged, 0);
	atomic_store(&next_step, step);
	for (uint32_t tries = 0; responded && tries < TRIES && atomic_load(&raced) < RACED_WANTED &&
	    atomic_load(&damaged) == 0; tries++) {
		++*round;
		atomic_store_explicit(&round_next, *round, memory_order_release);
		responded = wait_for_word(&round_armed, *round);
		up_at = erx_fiasco_clock_ns() + UP_AFTER_NS;
		while (erx_fiasco_clock_ns() < up_at)
			;
		raced_before = atomic_load(&raced);
		up_took = erx_fiasco_clock_ns();
		erx_fiasco_test_semaphore_up(waiter_semaphore);
		up_took = erx_fiasco_clock_ns() - up_took;
		responded = responded && wait_for_word(&round_done, *round);
		/*
		 * An up held for less than the hold found the waiter queued again, which shows
		 * as damage, or found it not queued at all: its vCPU stalled before the down, which
		 * then took a count and raced nothing, whatever the waiter's clock said.
		 */
		if (atomic_load(&raced) > raced_before && atomic_load(&damaged) == 0 && up_took < HOLD_NS / 2)
			atomic_fetch_sub(&raced, 1);
	}
	say("erx: semaphore-race: ");
	say(name);
	say(" raced ");
	say_number(atomic_load(&raced));
	say(" damaged ");
	say_number(atomic_load(&damaged));
	if (responded && atomic_load(&raced) >= RACED_WANTED && atomic_load(&damaged) == 0) {
		say(" ok\n");
		return (true);
	}
	say(" FAILED\n");
	return (false);
}

static bool
start_waiter(void)
{
	erx_fiasco_start_t start = { 0 };
	const uint64_t *const words = (const uint64_t *)(const void *)&start;
	erx_utcb_t *const utcb = erx_utcb_self();
	uint64_t thread;

	start.regs.sp = (uint64_t)(uintptr_t)(waiter_stack + STACK_BYTES);
	start.regs.pc = (uint64_t)(uintptr_t)waiter;
	for (size_t word = 0; word < sizeof(start) / sizeof(uint64_t); word++)
		atomic_store_explicit(&utcb->mr[word], words[word], memory_order_relaxed);
	atomic_store(&round_done, UINT32_MAX);
	return (erx_thread_create(0, 0, 0, ERX_THREAD_CLASS_WORKER, &thread) == ERX_OK &&
	    erx_thread_set_affinity(thread, UINT64_C(1) << 1) == ERX_OK && erx_thread_start(thread) == ERX_OK &&
	    wait_for_word(&round_done, 0));
}

void
erx_fiasco_root_main(void)
{
	const char *reason = erx_fiasco_root_up(NULL, 0, 0);
	uint32_t round = 0;
	bool undisturbed, second_waits;

	if (reason != NULL) {
		say(reason);
		erx_fiasco_machine_off();
	}
	say("erx: semaphore-race: service up\n");
	if (erx_fiasco_test_cpu_count() < 2) {
		say("erx: semaphore-race: needs two CPUs FAILED\n");
		erx_fiasco_machine_off();
	}
	/* This thread stays on the boot CPU, CPU 0, and the waiter runs on CPU 1. */
	if (!start_waiter()) {
		say("erx: semaphore-race: the waiter did not start FAILED\n");
		erx_fiasco_machine_off();
	}
	/* The second case last: on a kernel with the race it leaves the waiter still queued. */
	undisturbed = run_case("ipc_wait_undisturbed", WAITER_SLEEPS, &round);
	second_waits = run_case("second_down_waits", WAITER_DOWNS, &round);
	if (undisturbed && second_waits)
		say("erx: semaphore-race: done\n");
	erx_fiasco_machine_off();
}
