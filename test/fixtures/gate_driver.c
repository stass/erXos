/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host checks of the fault gates' core, liberx/backend/core/gate.c.
 *
 *   exhaustive  Every sequence of binds, posts, takes, cancels, withdrawals, closes
 *               and thread deletions over two gates, two threads and three entries,
 *               against a model of plain arrays: each step's woken thread, each
 *               taken record and the whole state after every step.
 *   protocol    The wait protocol with one thread and fake effects: a record at
 *               once, a post during the wait, a plain timeout, and a post as the
 *               deadline passes, whose up the wait must absorb.
 *   race        Real threads under a real lock: a poster against a waiter whose
 *               deadlines race the posts. A semaphore holding an up when its thread
 *               enters a wait is a stale count. Lost means no record taken for
 *               RACE_PATIENCE_NS, judged from the last take rather than over the whole
 *               run, whose length a loaded host stretches.
 *
 * Prints what it covered and exits 0, or names the first disagreement and exits 1.
 */

#include <pthread.h>
#include <sched.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "erx/abi.h"
#include "liberx/backend/core/gate.h"

#define GATES		2
#define THREADS		2
#define ENTRIES		3
#define DEPTH		5
#define RACE_ROUNDS	20000u
#define RACE_PATIENCE_NS (UINT64_C(20) * 1000000000)
#define PAGE_BYTES	4096u

static _Noreturn void
fail(const char *what)
{
	printf("disagreement: %s\n", what);
	exit(1);
}

/* The grow table's pages, from the host's allocator. */
static uintptr_t
page_take(void)
{
	void *page = NULL;

	return (posix_memalign(&page, PAGE_BYTES, PAGE_BYTES) == 0 ? (uintptr_t)page : 0);
}

static void
page_give(uintptr_t page)
{
	free((void *)page);
}

static const erx_backend_grow_pages_t pages = { .take = page_take, .give = page_give };

/* exhaustive */

enum { OP_BIND, OP_POST, OP_TAKE, OP_CANCEL, OP_WITHDRAW, OP_CLOSE, OP_GONE };

typedef struct op {
	int	kind;
	int	gate;
	int	thread;		/* -1 for NULL in a bind */
	int	entry;
} op_t;

typedef struct model {
	int	bound[GATES];		/* -1 for none */
	int	queue[GATES][ENTRIES];	/* entry numbers, oldest first */
	int	length[GATES];
	int	gate_of[ENTRIES];	/* -1 when unqueued */
	uint64_t order[ENTRIES];
	bool	listed[THREADS];
	uint64_t posted;
} model_t;

static op_t ops[64];
static int op_count;
static uint64_t sequences;

static void
ops_build(void)
{
	for (int gate = 0; gate < GATES; gate++)
		for (int thread = -1; thread < THREADS; thread++)
			ops[op_count++] = (op_t){ .kind = OP_BIND, .gate = gate, .thread = thread };
	for (int gate = 0; gate < GATES; gate++)
		for (int entry = 0; entry < ENTRIES; entry++)
			ops[op_count++] = (op_t){ .kind = OP_POST, .gate = gate, .entry = entry };
	for (int thread = 0; thread < THREADS; thread++) {
		ops[op_count++] = (op_t){ .kind = OP_TAKE, .thread = thread };
		ops[op_count++] = (op_t){ .kind = OP_CANCEL, .thread = thread };
		ops[op_count++] = (op_t){ .kind = OP_GONE, .thread = thread };
	}
	for (int entry = 0; entry < ENTRIES; entry++)
		ops[op_count++] = (op_t){ .kind = OP_WITHDRAW, .entry = entry };
	for (int gate = 0; gate < GATES; gate++)
		ops[op_count++] = (op_t){ .kind = OP_CLOSE, .gate = gate };
}

static void
model_unqueue(model_t *model, int entry)
{
	const int gate = model->gate_of[entry];
	int at = 0;

	while (model->queue[gate][at] != entry)
		at++;
	memmove(&model->queue[gate][at], &model->queue[gate][at + 1],
	    (size_t)(model->length[gate] - at - 1) * sizeof(int));
	model->length[gate]--;
	model->gate_of[entry] = -1;
}

/* The model's wake: the bound thread, if listed and the gate holds a record. */
static int
model_wake(model_t *model, int gate)
{
	const int thread = model->bound[gate];

	if (thread < 0 || !model->listed[thread] || model->length[gate] == 0)
		return (-1);
	model->listed[thread] = false;
	return (thread);
}

typedef struct world {
	erx_backend_gates_t gates;
	erx_backend_gate_entry_t entries[ENTRIES];
} world_t;

/* The model's thread n is the core's id n + 1, so id 0 is none. */
static int
thread_number(uint64_t thread)
{
	return ((int)thread - 1);
}

static bool
listed(const world_t *world, int thread)
{
	const uint64_t *const word = erx_backend_grow_table_at(&world->gates.listed, 0);

	return (word != NULL && (*word >> (thread + 1) & 1) != 0);
}

static void
state_check(const world_t *world, const model_t *model)
{
	for (int gate = 0; gate < GATES; gate++) {
		const erx_backend_gate_t *const real = erx_backend_gate_at(&world->gates, (uint32_t)gate);
		const erx_backend_gate_entry_t *entry = real->head;

		if (thread_number(real->thread) != model->bound[gate])
			fail("a gate's binding");
		for (int at = 0; at < model->length[gate]; at++, entry = entry->next)
			if (entry != &world->entries[model->queue[gate][at]])
				fail("a gate's queue, oldest first");
		if (entry != NULL)
			fail("a gate's queue holds more than it was given");
	}
	for (int entry = 0; entry < ENTRIES; entry++) {
		const erx_backend_gate_t *const gate = world->entries[entry].gate;

		if ((gate == NULL ? -1 : (int)(gate - erx_backend_gate_at(&world->gates, 0))) != model->gate_of[entry])
			fail("an entry queued where no queue holds it");
	}
	for (int thread = 0; thread < THREADS; thread++)
		if (listed(world, thread) != model->listed[thread])
			fail("a thread's listing");
}

static void
step(world_t *world, model_t *model, const op_t *op)
{
	const uint64_t thread = (uint64_t)(op->thread + 1);
	erx_fault_t record = { 0 };
	uint64_t label = 0;
	int expected;

	switch (op->kind) {
	case OP_BIND:
		model->bound[op->gate] = op->thread;
		expected = model_wake(model, op->gate);
		if (thread_number(erx_backend_gate_bind(&world->gates,
		    erx_backend_gate_at(&world->gates, (uint32_t)op->gate), thread)) != expected)
			fail("lost wake: a bind's");
		break;
	case OP_POST: {
		const erx_fault_t posted = { .kind = ERX_FAULT_MEMORY, .addr = (uint64_t)op->entry, .pc = model->posted };

		/* An entry is posted only while unqueued, as its record's owner ensures. */
		if (model->gate_of[op->entry] >= 0)
			break;
		model->queue[op->gate][model->length[op->gate]++] = op->entry;
		model->gate_of[op->entry] = op->gate;
		model->order[op->entry] = model->posted++;
		expected = model_wake(model, op->gate);
		if (thread_number(erx_backend_gate_post(&world->gates, erx_backend_gate_at(&world->gates,
		    (uint32_t)op->gate), &world->entries[op->entry], &posted, 100 + (uint64_t)op->entry)) != expected)
			fail("lost wake: a post's");
		break;
	}
	case OP_TAKE: {
		int oldest = -1;
		bool taken;

		for (int gate = 0; gate < GATES; gate++)
			if (model->bound[gate] == op->thread && model->length[gate] > 0 &&
			    (oldest < 0 || model->order[model->queue[gate][0]] < model->order[oldest]))
				oldest = model->queue[gate][0];
		if (oldest >= 0)
			model_unqueue(model, oldest);
		else
			model->listed[op->thread] = true;
		if (erx_backend_gate_take(&world->gates, thread, &taken, &record, &label) != ERX_OK)
			fail("a take refused");
		if (oldest < 0 ? taken : !taken || world->entries[oldest].gate != NULL || record.addr != (uint64_t)oldest ||
		    record.pc != model->order[oldest] || label != 100 + (uint64_t)oldest)
			fail("a take: the oldest record of the thread's gates");
		break;
	}
	case OP_CANCEL:
		if (erx_backend_gate_cancel(&world->gates, thread) != model->listed[op->thread])
			fail("a cancel's answer");
		model->listed[op->thread] = false;
		break;
	case OP_WITHDRAW:
		if (model->gate_of[op->entry] >= 0)
			model_unqueue(model, op->entry);
		erx_backend_gate_withdraw(&world->entries[op->entry]);
		break;
	case OP_CLOSE:
		/* A close and the same index opened again, as a new object's record takes it. */
		while (model->length[op->gate] > 0)
			model_unqueue(model, model->queue[op->gate][0]);
		model->bound[op->gate] = -1;
		erx_backend_gate_close(&world->gates, (uint32_t)op->gate);
		if (erx_backend_gate_at(&world->gates, (uint32_t)op->gate) != NULL)
			fail("a close: the gate still lives");
		if (erx_backend_gate_open(&world->gates, (uint32_t)op->gate) != ERX_OK)
			fail("a gate's reopening");
		break;
	case OP_GONE:
		for (int gate = 0; gate < GATES; gate++)
			if (model->bound[gate] == op->thread)
				model->bound[gate] = -1;
		model->listed[op->thread] = false;
		erx_backend_gate_thread_gone(&world->gates, thread);
		break;
	default:
		fail("no such step");
	}
	state_check(world, model);
}

static void
replay(const int *sequence, int count)
{
	world_t world = { 0 };
	model_t model = { 0 };

	erx_backend_gates_init(&world.gates, &pages);
	for (int gate = 0; gate < GATES; gate++) {
		if (erx_backend_gate_open(&world.gates, (uint32_t)gate) != ERX_OK)
			fail("a gate's opening");
		model.bound[gate] = -1;
	}
	for (int entry = 0; entry < ENTRIES; entry++)
		model.gate_of[entry] = -1;
	for (int at = 0; at < count; at++)
		step(&world, &model, &ops[sequence[at]]);
	erx_backend_gates_clear(&world.gates);
	sequences++;
}

static void
walk(int *sequence, int count)
{
	replay(sequence, count);
	if (count == DEPTH)
		return;
	for (int op = 0; op < op_count; op++) {
		sequence[count] = op;
		walk(sequence, count + 1);
	}
}

static void
run_exhaustive(void)
{
	int sequence[DEPTH];

	ops_build();
	walk(sequence, 0);
	printf("exhaustive: %llu sequences\n", (unsigned long long)sequences);
}

/* protocol */

typedef enum scenario {
	SCENARIO_AT_ONCE,	/* a record is queued before the wait */
	SCENARIO_DURING,	/* a post during the down */
	SCENARIO_TIMEOUT,	/* nothing comes */
	SCENARIO_AT_DEADLINE	/* a post as the deadline passes, before the cancel */
} scenario_t;

typedef struct fake {
	erx_backend_gates_t gates;
	erx_backend_gate_entry_t entry;
	scenario_t scenario;
	int semaphore;
	int downs;
} fake_t;

static void
fake_post(fake_t *fake)
{
	const erx_fault_t record = { .kind = ERX_FAULT_EXIT };

	if (erx_backend_gate_post(&fake->gates, erx_backend_gate_at(&fake->gates, 0), &fake->entry, &record, 1) != 0)
		fake->semaphore++;
}

static bool
fake_take(void *context, int *status)
{
	fake_t *const fake = context;
	erx_fault_t record;
	uint64_t label;
	bool taken = false;

	*status = erx_backend_gate_take(&fake->gates, 1, &taken, &record, &label);
	return (taken);
}

static bool
fake_down(void *context, uint64_t deadline)
{
	fake_t *const fake = context;

	(void)deadline;
	if (fake->downs++ > 0)
		fail("a second down: the wait went round again");
	if (fake->scenario == SCENARIO_DURING)
		fake_post(fake);
	if (fake->semaphore > 0) {
		fake->semaphore--;
		return (true);
	}
	if (fake->scenario == SCENARIO_AT_DEADLINE)
		fake_post(fake);
	return (false);
}

static bool
fake_cancel(void *context)
{
	fake_t *const fake = context;

	return (erx_backend_gate_cancel(&fake->gates, 1));
}

static void
fake_absorb(void *context)
{
	fake_t *const fake = context;

	if (fake->semaphore == 0)
		fail("an absorb with no up on its way");
	fake->semaphore--;
}

static const erx_backend_gate_wait_effects_t fake_effects = { .take = fake_take, .down = fake_down,
    .cancel = fake_cancel, .absorb = fake_absorb };

static void
run_protocol(void)
{
	static const int expected[] = { ERX_OK, ERX_OK, ERX_ETIMEDOUT, ERX_ETIMEDOUT };

	for (int scenario = SCENARIO_AT_ONCE; scenario <= SCENARIO_AT_DEADLINE; scenario++) {
		fake_t fake = { .scenario = (scenario_t)scenario };
		erx_backend_gate_t *gate;

		erx_backend_gates_init(&fake.gates, &pages);
		if (erx_backend_gate_open(&fake.gates, 0) != ERX_OK)
			fail("a gate's opening");
		gate = erx_backend_gate_at(&fake.gates, 0);
		(void)erx_backend_gate_bind(&fake.gates, gate, 1);
		if (scenario == SCENARIO_AT_ONCE)
			fake_post(&fake);
		if (erx_backend_gate_wait(&fake_effects, &fake, 1) != expected[scenario])
			fail("a wait's result");
		if (fake.semaphore != 0)
			fail("stale count: the wait left an up behind");
		if (erx_backend_gate_cancel(&fake.gates, 1))
			fail("a wait returned with its thread listed");
		/* A record a timed-out wait left queued is the next wait's. */
		if (scenario == SCENARIO_AT_DEADLINE && gate->head != &fake.entry)
			fail("the record that came at the deadline is kept");
		erx_backend_gates_clear(&fake.gates);
	}
	printf("protocol: 4 scenarios\n");
}

/* race */

typedef struct real_semaphore {
	pthread_mutex_t	mutex;
	pthread_cond_t	cond;
	uint32_t	count;
} real_semaphore_t;

static pthread_mutex_t real_service = PTHREAD_MUTEX_INITIALIZER;
static erx_backend_gates_t real_gates;
static erx_backend_gate_entry_t real_entry;
static real_semaphore_t real_semaphore = { PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, 0 };
static _Atomic uint64_t real_posted, real_taken, real_timeouts;
static _Atomic uint32_t real_stop;

/* For the waits' deadlines: pthread_cond_timedwait on macOS reads the wall clock. */
static uint64_t
now_ns(void)
{
	struct timespec now;

	clock_gettime(CLOCK_REALTIME, &now);
	return ((uint64_t)now.tv_sec * 1000000000 + (uint64_t)now.tv_nsec);
}

/* For the watch's patience, which a step of the wall clock must not cut short. */
static uint64_t
monotonic_ns(void)
{
	struct timespec now;

	clock_gettime(CLOCK_MONOTONIC, &now);
	return ((uint64_t)now.tv_sec * 1000000000 + (uint64_t)now.tv_nsec);
}

static void
real_up(void)
{
	pthread_mutex_lock(&real_semaphore.mutex);
	real_semaphore.count++;
	pthread_cond_signal(&real_semaphore.cond);
	pthread_mutex_unlock(&real_semaphore.mutex);
}

static bool
real_take(void *context, int *status)
{
	erx_fault_t record;
	uint64_t label;
	bool taken = false;

	(void)context;
	pthread_mutex_lock(&real_service);
	*status = erx_backend_gate_take(&real_gates, 1, &taken, &record, &label);
	pthread_mutex_unlock(&real_service);
	if (taken)
		real_taken++;
	return (taken);
}

static bool
real_down(void *context, uint64_t deadline)
{
	struct timespec until = { .tv_sec = (time_t)(deadline / 1000000000), .tv_nsec = (long)(deadline % 1000000000) };
	bool got = true;

	(void)context;
	pthread_mutex_lock(&real_semaphore.mutex);
	while (real_semaphore.count == 0 && got)
		got = pthread_cond_timedwait(&real_semaphore.cond, &real_semaphore.mutex, &until) == 0;
	if (real_semaphore.count > 0) {
		real_semaphore.count--;
		got = true;
	}
	pthread_mutex_unlock(&real_semaphore.mutex);
	return (got);
}

static bool
real_cancel(void *context)
{
	bool listed;

	(void)context;
	pthread_mutex_lock(&real_service);
	listed = erx_backend_gate_cancel(&real_gates, 1);
	pthread_mutex_unlock(&real_service);
	return (listed);
}

static void
real_absorb(void *context)
{
	(void)context;
	pthread_mutex_lock(&real_semaphore.mutex);
	while (real_semaphore.count == 0)
		pthread_cond_wait(&real_semaphore.cond, &real_semaphore.mutex);
	real_semaphore.count--;
	pthread_mutex_unlock(&real_semaphore.mutex);
}

static const erx_backend_gate_wait_effects_t real_effects = { .take = real_take, .down = real_down,
    .cancel = real_cancel, .absorb = real_absorb };

/* Waits with deadlines from nothing to a few microseconds, so timeouts race the posts. */
static void *
real_waiter(void *argument)
{
	uint64_t round = 0;

	(void)argument;
	while (!real_stop) {
		pthread_mutex_lock(&real_semaphore.mutex);
		if (real_semaphore.count != 0) {
			pthread_mutex_unlock(&real_semaphore.mutex);
			fail("stale count: an up waits as the thread enters a wait");
		}
		pthread_mutex_unlock(&real_semaphore.mutex);
		if (erx_backend_gate_wait(&real_effects, NULL, now_ns() + round++ % 8 * 1000) == ERX_ETIMEDOUT)
			real_timeouts++;
	}
	return (NULL);
}

/*
 * Posts the one entry each time the waiter has taken it. While the entry is still
 * queued it yields: on a loaded host, a poster spinning on the service lock takes
 * the CPU the waiter needs to take the entry.
 */
static void *
real_poster(void *argument)
{
	const erx_fault_t record = { .kind = ERX_FAULT_MEMORY };

	(void)argument;
	while (real_posted < RACE_ROUNDS) {
		uint64_t woken = 0;
		bool posted = false;

		pthread_mutex_lock(&real_service);
		if (real_entry.gate == NULL) {
			woken = erx_backend_gate_post(&real_gates, erx_backend_gate_at(&real_gates, 0), &real_entry, &record, 0);
			posted = true;
		}
		pthread_mutex_unlock(&real_service);
		if (posted)
			real_posted++;
		if (woken != 0)
			real_up();
		if (!posted)
			(void)sched_yield();
	}
	return (NULL);
}

/*
 * Waits for the last record to be taken, checking every millisecond. Progress is the
 * judge: the run fails only when no record has been taken for RACE_PATIENCE_NS.
 */
static void
real_watch(void)
{
	const struct timespec tick = { .tv_sec = 0, .tv_nsec = 1000000 };
	uint64_t seen = 0, since = monotonic_ns();

	while (real_taken < RACE_ROUNDS) {
		const uint64_t taken = real_taken, now = monotonic_ns();

		if (taken != seen) {
			seen = taken;
			since = now;
		} else if (now - since > RACE_PATIENCE_NS) {
			char what[128];

			/* A lost record leaves one more posted than taken; equal counts mean the poster stalled. */
			(void)snprintf(what, sizeof(what), "lost: no record taken in %llu s (%llu posted, %llu taken)",
			    (unsigned long long)(RACE_PATIENCE_NS / 1000000000), (unsigned long long)real_posted,
			    (unsigned long long)taken);
			fail(what);
		}
		(void)nanosleep(&tick, NULL);
	}
}

static void
run_race(void)
{
	pthread_t waiter, poster;

	erx_backend_gates_init(&real_gates, &pages);
	if (erx_backend_gate_open(&real_gates, 0) != ERX_OK)
		fail("a gate's opening");
	(void)erx_backend_gate_bind(&real_gates, erx_backend_gate_at(&real_gates, 0), 1);
	pthread_create(&waiter, NULL, real_waiter, NULL);
	pthread_create(&poster, NULL, real_poster, NULL);
	real_watch();
	pthread_join(poster, NULL);
	real_stop = 1;
	pthread_join(waiter, NULL);
	erx_backend_gates_clear(&real_gates);
	printf("race: %u records, %llu timeouts\n", RACE_ROUNDS, (unsigned long long)real_timeouts);
}

int
main(int argc, char **argv)
{
	const char *const mode = argc > 1 ? argv[1] : "";

	if (strcmp(mode, "exhaustive") == 0)
		run_exhaustive();
	else if (strcmp(mode, "protocol") == 0)
		run_protocol();
	else if (strcmp(mode, "race") == 0)
		run_race();
	else
		fail("no such mode");
	return (0);
}
