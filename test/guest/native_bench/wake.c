/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The wake benchmark's cells (docs/design-bench.md, "1. `wake`: how late a waiting
 * thread runs"): two executors of the root's group time the landing matrix's wake cells.
 *
 * Executor 0 runs on the root's CPU, executor 1 on the last CPU. The root is thread A of
 * every handshake: it waits until B, an executor, is parked for the sample it is about to
 * take (native_irq's handshake), stamps, pokes B (erx_executor_wake for B's slot, or
 * erx_irq_trigger on a doorbell bound to the group), and blocks until B has stamped its
 * return. park-deadline is executor 0 alone, on the phase sweep's deadlines. The cross-CPU
 * cell is calibrated before and after it, between the root and executor 1.
 *
 * Every interval is ticks of erx_fiasco_counter. A wrong result in a cell is that cell's
 * failed status. Built with ERX_BENCH_SEED_LOST_WAKE, the root skips one wake of
 * wake-same-cpu, which must come back as a failed cell with one lost wake.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/group.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/park.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/thread.h"
#include "test/guest/bench/bench_periodic.h"
#include "test/guest/native_bench/bench_root.h"

#define LABEL_DOORBELL	UINT64_C(0x57a1)
#define PERIODS_PER_SECOND	UINT64_C(1000)
/* The first periodic deadline is this many periods after the run starts. */
#define PERIODIC_LEAD	10u
/* B parks this long for a wake; a park that reaches it lost its wake. */
#define WAKE_DEADLINE_NS	NS_PER_SECOND
#define EXECUTORS	BENCH_THREADS
#ifdef ERX_BENCH_SEED_LOST_WAKE
#define SEED_SKIPPED	(FAST_WARMUP + 3u)
#else
#define SEED_SKIPPED	UINT32_MAX
#endif

const char bench_benchmark[] = "wake";
/* What B found when it returned for a sample. */
typedef enum {
	RESULT_OK = 1,
	RESULT_LOST,	/* the park reached its deadline: a lost wake */
	RESULT_WRONG	/* a wrong status, a wrong label, or a label twice */
} result_t;

/*
 * One executor's side of the handshake. B raises ready to the sample's number before it
 * parks for it, and after its return publishes its stamp and result, then raises done to
 * the same number; A reads stamp and result only after seeing done move.
 */
typedef struct {
	_Atomic uint32_t slot;
	_Atomic uint32_t started;
	_Atomic uint32_t ready;
	_Atomic uint32_t done;
	_Atomic uint64_t stamp;
	_Atomic uint32_t result;
} handshake_t;

/* How A pokes B: a wake of B's slot, or a trigger of the doorbell. */
typedef enum {
	POKE_WAKE,
	POKE_TRIGGER
} poke_t;

/* What one handshake run gave: its samples, B's stamp less A's, and how it ended. */
typedef struct {
	size_t samples;
	result_t ended;
	uint32_t lost;
} run_t;

static handshake_t shakes[EXECUTORS];
static uint64_t root_group, doorbell;
static int64_t raw[FAST_SAMPLES];
static uint64_t values[FAST_SAMPLES];
static erx_bench_stamp_t stamps[PERIODIC_SAMPLES];
static erx_bench_periodic_t periodic;
static uint64_t periodic_first, periodic_period;
/* The stamps park_deadlines took before it ended, published with periodic_result. */
static size_t periodic_taken;
static _Atomic uint32_t periodic_result;

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

static bool
parked(uint32_t slot)
{
	return (atomic_load_explicit(&erx_fiasco_group_status()->exec[slot].state, memory_order_acquire) ==
	    ERX_EXEC_STATE_PARKED);
}

/* The counter tick as erx_fiasco_clock_ns names it: a park to it ends at the tick or later. */
static uint64_t
tick_ns(uint64_t ticks)
{
	const uint64_t hz = erx_fiasco_counter_hz();

	return (ticks / hz * NS_PER_SECOND + ticks % hz * NS_PER_SECOND / hz);
}

/* B publishes one sample's end. */
static void
publish(handshake_t *shake, uint32_t number, result_t result)
{
	atomic_store_explicit(&shake->stamp, erx_fiasco_counter(), memory_order_relaxed);
	atomic_store_explicit(&shake->result, result, memory_order_relaxed);
	atomic_store_explicit(&shake->done, number, memory_order_release);
}

/* B's park for sample number; the result its return means for a wake. */
static result_t
park_for(handshake_t *shake, uint32_t number, uint64_t group, uint64_t epoch)
{
	int status;

	atomic_store_explicit(&shake->ready, number, memory_order_release);
	status = erx_park(group, epoch, erx_fiasco_clock_ns() + WAKE_DEADLINE_NS);
	if (status == ERX_OK)
		return (RESULT_OK);
	return (status == ERX_ETIMEDOUT ? RESULT_LOST : RESULT_WRONG);
}

/* wake-same-cpu and wake-cross-cpu, B's side: one park per sample, A's wake ends it. */
static void
wake_b(handshake_t *shake, uint32_t slot, uint32_t total)
{
	for (uint32_t number = 1; number <= total; number++) {
		const result_t result = park_for(shake, number, group_epoch(), slot_epoch(slot));

		publish(shake, number, result);
		if (result != RESULT_OK)
			return;
	}
}

/* trigger-take, B's side: the runtime's loop of take, then park, until the doorbell's label. */
static void
take_b(handshake_t *shake, uint32_t slot, uint32_t total)
{
	for (uint32_t number = 1; number <= total; number++) {
		result_t result = RESULT_OK;
		int taken;

		/* The runtime's loop: the epochs before the empty check, then the park on them. */
		for (;;) {
			const uint64_t group = group_epoch(), epoch = slot_epoch(slot);

			taken = erx_group_take_ready(ERX_MSG_WORDS);
			if (taken != 0 || (result = park_for(shake, number, group, epoch)) != RESULT_OK)
				break;
		}
		if (result == RESULT_OK && (taken != 1 ||
		    atomic_load_explicit(&erx_utcb_self()->mr[0], memory_order_relaxed) != LABEL_DOORBELL ||
		    erx_group_take_ready(ERX_MSG_WORDS) != 0))
			result = RESULT_WRONG;
		publish(shake, number, result);
		if (result != RESULT_OK)
			return;
	}
}

/* park-deadline: executor 0 alone parks on each deadline of the phase sweep and stamps its return. */
static void
park_deadlines(uint32_t slot)
{
	uint32_t k = 0;

	periodic_period = erx_fiasco_counter_hz() / PERIODS_PER_SECOND;
	periodic_first = erx_fiasco_counter() + PERIODIC_LEAD * periodic_period;
	for (size_t n = 0; n < PERIODIC_SAMPLES; n++) {
		const uint64_t deadline = erx_bench_periodic_deadline(periodic_first, periodic_period, k);
		const int status = erx_park(group_epoch(), slot_epoch(slot), tick_ns(deadline));

		stamps[n] = (erx_bench_stamp_t){ .k = k, .returned = erx_fiasco_counter() };
		if (status != ERX_ETIMEDOUT) {
			periodic_taken = n;
			atomic_store_explicit(&periodic_result, RESULT_WRONG, memory_order_release);
			return;
		}
		k = erx_bench_periodic_next(periodic_first, periodic_period, k, stamps[n].returned);
	}
	periodic_taken = PERIODIC_SAMPLES;
	atomic_store_explicit(&periodic_result, RESULT_OK, memory_order_release);
}

static void
executor_0(void)
{
	const uint32_t slot = erx_fiasco_thread_self()->executor_slot;

	park_deadlines(slot);
	wake_b(&shakes[0], slot, FAST_WARMUP + FAST_SAMPLES);
	take_b(&shakes[0], slot, FAST_WARMUP + FAST_SAMPLES);
}

static void
executor_1(void)
{
	const uint32_t slot = erx_fiasco_thread_self()->executor_slot;

	bench_calibrate_b();
	wake_b(&shakes[1], slot, FAST_WARMUP + FAST_SAMPLES);
	bench_calibrate_b();
}

static void
executor_main(uint64_t index)
{
	handshake_t *const shake = &shakes[index];

	atomic_store_explicit(&shake->slot, erx_fiasco_thread_self()->executor_slot, memory_order_relaxed);
	atomic_store_explicit(&shake->started, 1, memory_order_release);
	if (index == 0)
		executor_0();
	else
		executor_1();
	erx_fiasco_sleep_forever();
}

static void
start_executor(uint32_t index, uint32_t cpu)
{
	bench_thread_start(index, cpu, ERX_THREAD_CLASS_EXECUTOR, executor_main);
	while (atomic_load_explicit(&shakes[index].started, memory_order_acquire) == 0)
		bench_wait_poll();
}

/* A's wait for a value of B's to reach number, which a stuck B ends as a failed boot. */
static void
await(_Atomic uint32_t *value, uint32_t number, uint32_t slot, bool want_parked)
{
	const uint64_t until = erx_fiasco_clock_ns() + PATIENCE_NS;

	while (atomic_load_explicit(value, memory_order_acquire) != number || (want_parked && !parked(slot))) {
		if (erx_fiasco_clock_ns() > until)
			bench_fail("erx: bench: an executor stopped answering FAILED\n");
		bench_wait_poll();
	}
}

/*
 * A's side of a handshake run with executor index: warm-up, then FAST_SAMPLES samples of
 * B's return stamp less A's poke stamp, into raw. Ends at the first wrong result.
 */
static run_t
handshake_a(uint32_t index, poke_t poke)
{
	handshake_t *const shake = &shakes[index];
	const uint32_t slot = atomic_load_explicit(&shake->slot, memory_order_relaxed);
	run_t run = { .samples = 0, .ended = RESULT_OK, .lost = 0 };

	for (uint32_t number = 1; number <= FAST_WARMUP + FAST_SAMPLES; number++) {
		uint64_t poked;
		int status = ERX_OK;

		await(&shake->ready, number, slot, true);
		poked = erx_fiasco_counter();
		if (poke == POKE_TRIGGER)
			status = erx_irq_trigger(doorbell);
		else if (index != 0 || poke != POKE_WAKE || number != SEED_SKIPPED)
			status = erx_executor_wake(slot);
		if (status != ERX_OK)
			bench_fail("erx: bench: a wake or a trigger was refused FAILED\n");
		await(&shake->done, number, slot, false);
		run.ended = (result_t)atomic_load_explicit(&shake->result, memory_order_relaxed);
		if (run.ended != RESULT_OK) {
			run.lost = run.ended == RESULT_LOST;
			return (run);
		}
		if (number > FAST_WARMUP)
			raw[run.samples++] = (int64_t)(atomic_load_explicit(&shake->stamp, memory_order_relaxed) - poked);
	}
	return (run);
}

/* A handshake run's cell from its samples in values. */
static void
print_run(erx_bench_cell_t cell, run_t run)
{
	erx_bench_sample_t top[ERX_BENCH_LARGEST];

	if (run.ended != RESULT_OK) {
		cell.status = "failed";
		cell.reason = run.ended == RESULT_LOST ? "lost wake" : "wrong result";
		cell.lost = run.lost;
	}
	bench_summarize(&cell, values, run.samples, top);
	bench_print(&cell);
}

/* A run's samples into values, less offset: B's counter less A's, 0 on one CPU. */
static void
correct(run_t run, int64_t offset)
{
	for (size_t at = 0; at < run.samples; at++) {
		/* A corrected sample below zero lies within the uncertainty the cell states. */
		const int64_t corrected = raw[at] - offset;

		values[at] = corrected < 0 ? 0 : (uint64_t)corrected;
	}
}

static void
print_periodic(void)
{
	erx_bench_cell_t cell = bench_cell_of("park-deadline", "service-cpu");
	erx_bench_sample_t top[ERX_BENCH_LARGEST];
	size_t on_time = 0;

	erx_bench_periodic_classify(periodic_first, periodic_period, stamps, periodic_taken, &periodic);
	for (size_t at = 0; at < periodic_taken; at++) {
		const uint64_t deadline = erx_bench_periodic_deadline(periodic_first, periodic_period, stamps[at].k);

		if (stamps[at].returned >= deadline)
			values[on_time++] = stamps[at].returned - deadline;
	}
	bench_summarize(&cell, values, on_time, top);
	cell.hist = &periodic.late;
	cell.early = periodic.early;
	cell.missed = periodic.missed;
	cell.periodic = &periodic;
	if (atomic_load_explicit(&periodic_result, memory_order_acquire) != RESULT_OK) {
		cell.status = "failed";
		cell.reason = "a park with no wake did not answer ERX_ETIMEDOUT";
	} else if (periodic.early != 0) {
		cell.status = "failed";
		cell.reason = "early return";
	}
	bench_print(&cell);
}

static void
bind_doorbell(void)
{
	if (erx_group_create(0, 0, &root_group) != ERX_OK)
		bench_fail("erx: bench: no group FAILED\n");
	if (erx_irq_create(0, 0, ERX_IRQ_SOFT, 0, &doorbell, NULL) != ERX_OK ||
	    erx_irq_bind(doorbell, root_group, LABEL_DOORBELL) != ERX_OK)
		bench_fail("erx: bench: no doorbell FAILED\n");
}

/* The cells on executor 0, the root's CPU: park-deadline, then the two same-CPU handshakes. */
static void
same_cpu_cells(void)
{
	run_t wake, take;

	start_executor(0, 0);
	while (atomic_load_explicit(&periodic_result, memory_order_acquire) == 0)
		bench_wait_poll();
	print_periodic();
	wake = handshake_a(0, POKE_WAKE);
	correct(wake, 0);
	print_run(bench_cell_of("wake-same-cpu", "same-cpu"), wake);
	if (wake.ended != RESULT_OK)
		return;
	take = handshake_a(0, POKE_TRIGGER);
	correct(take, 0);
	print_run(bench_cell_of("trigger-take", "same-cpu"), take);
}

/* wake-cross-cpu on executor 1, calibrated before and after; returns the pair for the CLOCK line. */
static erx_bench_pair_t
cross_cpu_cell(uint32_t last)
{
	erx_bench_cell_t cell = bench_cell_of("wake-cross-cpu", "cross-cpu");
	erx_bench_pair_t pair = { .cpus = { 0, last } };
	erx_bench_sample_t top[ERX_BENCH_LARGEST];
	erx_bench_offset_t hull;
	const char *unsupported;
	run_t run;

	start_executor(1, last);
	pair.before = bench_calibrate_a();
	run = handshake_a(1, POKE_WAKE);
	pair.after = bench_calibrate_a();
	hull = erx_bench_offset_hull(pair.before, pair.after);
	correct(run, hull.empty ? 0 : hull.low + (hull.high - hull.low) / 2);
	/* The bound is a tenth of the corrected median, as the host holds it. */
	bench_summarize(&cell, values, run.samples, top);
	unsupported = erx_bench_cell_unsupported(true, pair.before, pair.after, erx_bench_hist_median(&bench_hist));
	if (unsupported == NULL) {
		cell.has_uncertainty = true;
		cell.uncertainty = erx_bench_offset_half_width(hull);
	} else if (run.ended == RESULT_OK) {
		bench_print_unsupported(cell, unsupported);
		return (pair);
	} else {
		/* A failure keeps its counts, not statistics no calibration vouches for. */
		run.samples = 0;
	}
	print_run(cell, run);
	return (pair);
}

void
bench_cells(uint32_t cpus, const erx_pack_view_t *pack)
{
	erx_bench_pair_t pair;

	(void)pack;
	bind_doorbell();
	same_cpu_cells();
	if (cpus > 1) {
		pair = cross_cpu_cell(cpus - 1);
		bench_print_clock(&pair, 1);
	} else {
		bench_print_unsupported(bench_cell_of("wake-cross-cpu", "cross-cpu"), "the machine has one CPU");
		bench_print_clock(NULL, 0);
	}
}
