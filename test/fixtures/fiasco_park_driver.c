/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The park protocol's core on the host. "exhaustive" walks every interleaving of
 * two executors, three events (a trigger of either of two objects, or a wake of
 * either slot), two timeouts and the landing of each up. "race" runs the same
 * calls under real threads, for ThreadSanitizer.
 *
 * An executor's program is the runtime's: read the epochs, look for work, park.
 * What can go wrong shows in three checks: at rest no work may wait while both
 * executors sleep (a lost wake); a park may not sleep with an up already due to its
 * slot (a stale count); and a trigger takes the longest parked slot.
 */

#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "liberx/backend/fiasco/park_table.h"

#define EXECUTORS	2u
#define OBJECTS		2u
#define EVENTS		3u
#define TIMEOUTS	2u
#define MEMO_ENTRIES	(UINT64_C(1) << 22)

typedef enum pc {
	PC_READ,
	PC_LOOK,
	PC_PARK,
	PC_SLEEP,
	PC_TIMEOUT,
	PC_ABSORB
} pc_t;

/* What the waker is in the middle of: it publishes first and steps second. */
typedef enum source {
	SOURCE_IDLE,
	SOURCE_TRIGGER,
	SOURCE_WAKE_0,
	SOURCE_WAKE_1
} source_t;

typedef struct model {
	erx_fiasco_park_t park;
	uint8_t		pc[EXECUTORS];
	uint8_t		seen_group[EXECUTORS];
	uint8_t		seen_slot[EXECUTORS];
	uint8_t		semaphore[EXECUTORS];
	uint8_t		ups_flying[EXECUTORS];
	uint8_t		wake_flag[EXECUTORS];
	uint8_t		work;		/* one bit per object */
	uint8_t		source;
	uint8_t		events_left;
	uint8_t		timeouts_left;
} model_t;

typedef struct state_key {
	uint8_t		bytes[24];
} state_key_t;

static state_key_t *memo;
static uint64_t memo_used;
static uint64_t states;

static _Noreturn void
disagree(const char *what)
{
	printf("exhaustive: %s\n", what);
	exit(1);
}

static state_key_t
model_key(const model_t *state)
{
	state_key_t key = { { 0 } };
	size_t at = 0;

	key.bytes[at++] = 1;	/* never the all-zero empty entry */
	key.bytes[at++] = (uint8_t)state->park.group_epoch;
	key.bytes[at++] = (uint8_t)state->park.parked_count;
	for (uint32_t slot = 0; slot < EXECUTORS; slot++) {
		key.bytes[at++] = (uint8_t)state->park.slot_epoch[slot];
		key.bytes[at++] = state->park.parked[slot];
		key.bytes[at++] = state->pc[slot];
		key.bytes[at++] = state->seen_group[slot];
		key.bytes[at++] = state->seen_slot[slot];
		key.bytes[at++] = (uint8_t)(state->semaphore[slot] << 4 | state->ups_flying[slot] << 1 | state->wake_flag[slot]);
	}
	key.bytes[at++] = state->work;
	key.bytes[at++] = state->source;
	key.bytes[at++] = state->events_left;
	key.bytes[at] = state->timeouts_left;
	return (key);
}

/* Whether this state is new. The table holds whole keys, so no two states are confused. */
static bool
memo_insert(const model_t *state)
{
	const state_key_t key = model_key(state);
	uint64_t hash = UINT64_C(14695981039346656037);

	for (size_t at = 0; at < sizeof(key.bytes); at++)
		hash = (hash ^ key.bytes[at]) * UINT64_C(1099511628211);
	for (uint64_t probe = hash % MEMO_ENTRIES;; probe = (probe + 1) % MEMO_ENTRIES) {
		if (memo[probe].bytes[0] == 0) {
			if (++memo_used >= MEMO_ENTRIES - 1)
				disagree("the table of states is full");
			memo[probe] = key;
			return (true);
		}
		if (memcmp(memo[probe].bytes, key.bytes, sizeof(key.bytes)) == 0)
			return (false);
	}
}

static void explore(const model_t *);

static void
apply_result(model_t *next, erx_fiasco_park_result_t result)
{
	if (result.action == ERX_FIASCO_PARK_UP)
		next->ups_flying[result.slot]++;
}

/* The moves of one executor; returns whether it had any. */
static bool
explore_executor(const model_t *state, uint32_t slot)
{
	model_t next = *state;

	switch ((pc_t)state->pc[slot]) {
	case PC_READ:
		next.seen_group[slot] = (uint8_t)state->park.group_epoch;
		next.seen_slot[slot] = (uint8_t)state->park.slot_epoch[slot];
		next.pc[slot] = PC_LOOK;
		break;
	case PC_LOOK:
		next.pc[slot] = state->work != 0 || state->wake_flag[slot] != 0 ? PC_READ : PC_PARK;
		next.work = 0;
		next.wake_flag[slot] = 0;
		break;
	case PC_PARK: {
		const erx_fiasco_park_event_t event = { .op = ERX_FIASCO_PARK_OP_PARK, .slot = slot,
		    .group_seen = state->seen_group[slot], .slot_seen = state->seen_slot[slot] };
		const erx_fiasco_park_result_t result = erx_fiasco_park_step(&next.park, &event);

		if (result.action == ERX_FIASCO_PARK_SLEEP) {
			if (state->semaphore[slot] != 0 || state->ups_flying[slot] != 0)
				disagree("a stale count: a park sleeps with an up due");
			next.pc[slot] = PC_SLEEP;
		} else {
			next.pc[slot] = PC_READ;
		}
		break;
	}
	case PC_SLEEP:
		if (state->timeouts_left != 0) {
			next.timeouts_left--;
			next.pc[slot] = PC_TIMEOUT;
			explore(&next);
			next = *state;
		}
		if (state->semaphore[slot] == 0)
			return (state->timeouts_left != 0);
		next.semaphore[slot]--;
		next.pc[slot] = PC_READ;
		break;
	case PC_TIMEOUT: {
		const erx_fiasco_park_event_t event = { .op = ERX_FIASCO_PARK_OP_TIMEOUT, .slot = slot };
		const erx_fiasco_park_result_t result = erx_fiasco_park_step(&next.park, &event);

		next.pc[slot] = result.action == ERX_FIASCO_PARK_OWED ? PC_ABSORB : PC_READ;
		break;
	}
	case PC_ABSORB:
		if (state->semaphore[slot] == 0)
			return (false);
		next.semaphore[slot]--;
		next.pc[slot] = PC_READ;
		break;
	}
	explore(&next);
	return (true);
}

static bool
explore_source(const model_t *state)
{
	model_t next;
	bool moved = false;

	if (state->source != SOURCE_IDLE) {
		next = *state;
		const uint32_t slot = state->source == SOURCE_WAKE_1 ? 1u : 0u;
		const erx_fiasco_park_event_t event = { .op = state->source == SOURCE_TRIGGER ?
		    ERX_FIASCO_PARK_OP_TRIGGER : ERX_FIASCO_PARK_OP_WAKE, .slot = slot };
		const bool any_parked = state->park.parked_count != 0;
		const uint32_t oldest = state->park.parked[0];
		const erx_fiasco_park_result_t result = erx_fiasco_park_step(&next.park, &event);

		if (state->source == SOURCE_TRIGGER && any_parked &&
		    (result.action != ERX_FIASCO_PARK_UP || result.slot != oldest))
			disagree("oldest first: a trigger did not take the longest parked");
		apply_result(&next, result);
		next.source = SOURCE_IDLE;
		explore(&next);
		return (true);
	}
	if (state->events_left == 0)
		return (false);
	for (uint32_t object = 0; object < OBJECTS; object++) {
		next = *state;
		next.events_left--;
		next.work |= (uint8_t)(1u << object);
		next.source = SOURCE_TRIGGER;
		explore(&next);
		moved = true;
	}
	for (uint32_t slot = 0; slot < EXECUTORS; slot++) {
		next = *state;
		next.events_left--;
		next.wake_flag[slot] = 1;
		next.source = slot == 0 ? SOURCE_WAKE_0 : SOURCE_WAKE_1;
		explore(&next);
		moved = true;
	}
	return (moved);
}

static void
explore(const model_t *state)
{
	bool moved = false;

	if (!memo_insert(state))
		return;
	states++;
	for (uint32_t slot = 0; slot < EXECUTORS; slot++) {
		if (state->ups_flying[slot] != 0) {
			model_t next = *state;

			next.ups_flying[slot]--;
			next.semaphore[slot]++;
			explore(&next);
			moved = true;
		}
		moved |= explore_executor(state, slot);
	}
	moved |= explore_source(state);
	if (moved)
		return;
	/* At rest: nothing can move, so nothing else will ever look at the work. */
	if (state->work != 0 || state->wake_flag[0] != 0 || state->wake_flag[1] != 0)
		disagree("a lost wake: work waits and every executor sleeps");
}

static int
run_exhaustive(void)
{
	model_t start;

	memset(&start, 0, sizeof(start));
	start.park.used = 3;
	start.events_left = EVENTS;
	start.timeouts_left = TIMEOUTS;
	memo = calloc(MEMO_ENTRIES, sizeof(*memo));
	if (memo == NULL)
		disagree("no memory for the table of states");
	explore(&start);
	free(memo);
	printf("exhaustive: %llu states\n", (unsigned long long)states);
	return (0);
}

/* The race: real threads over the protocol, with semaphores like the kernel's. */
#define RACE_EXECUTORS	3u
#define RACE_ROUNDS	20000u

static erx_group_stat_t race_status;
static erx_fiasco_park_group_t race_group = { .status = &race_status };
static pthread_mutex_t race_lock_word = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t race_sem_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t race_sem_cond = PTHREAD_COND_INITIALIZER;
static uint32_t race_count[RACE_EXECUTORS];
static _Atomic uint32_t race_published;
static _Atomic uint32_t race_consumed;
static _Atomic uint32_t race_stop;
static _Atomic uint32_t race_flag[RACE_EXECUTORS];

static uint64_t
race_clock_ns(void)
{
	struct timespec now;

	clock_gettime(CLOCK_MONOTONIC, &now);
	return ((uint64_t)now.tv_sec * 1000000000u + (uint64_t)now.tv_nsec);
}

static void
race_lock(void *context)
{
	(void)context;
	pthread_mutex_lock(&race_lock_word);
}

static void
race_unlock(void *context)
{
	(void)context;
	pthread_mutex_unlock(&race_lock_word);
}

/* A deadline of a few tens of microseconds, polled as the fake's timer. */
static bool
race_down(void *context, uint32_t slot, uint64_t deadline)
{
	bool woken = false;

	(void)context;
	for (;;) {
		pthread_mutex_lock(&race_sem_lock);
		if (race_count[slot] != 0) {
			race_count[slot]--;
			woken = true;
		}
		pthread_mutex_unlock(&race_sem_lock);
		if (woken || race_clock_ns() >= deadline)
			return (woken);
		sched_yield();
	}
}

static void
race_absorb(void *context, uint32_t slot)
{
	(void)context;
	pthread_mutex_lock(&race_sem_lock);
	while (race_count[slot] == 0)
		pthread_cond_wait(&race_sem_cond, &race_sem_lock);
	race_count[slot]--;
	pthread_mutex_unlock(&race_sem_lock);
}

static void
race_up(void *context, uint32_t slot)
{
	(void)context;
	pthread_mutex_lock(&race_sem_lock);
	race_count[slot]++;
	pthread_cond_broadcast(&race_sem_cond);
	pthread_mutex_unlock(&race_sem_lock);
}

static const erx_fiasco_park_effects_t race_effects = { .lock = race_lock, .unlock = race_unlock,
    .down = race_down, .absorb = race_absorb, .up = race_up };

static void *
race_executor(void *argument)
{
	const uint32_t slot = (uint32_t)(uintptr_t)argument;

	while (atomic_load_explicit(&race_stop, memory_order_acquire) == 0) {
		const uint64_t group = atomic_load_explicit(&race_status.epoch, memory_order_acquire);
		const uint64_t epoch = atomic_load_explicit(&race_status.exec[slot].epoch, memory_order_acquire);
		uint32_t consumed = atomic_load_explicit(&race_consumed, memory_order_acquire);
		bool found = false;

		while (consumed < atomic_load_explicit(&race_published, memory_order_acquire)) {
			if (atomic_compare_exchange_weak_explicit(&race_consumed, &consumed, consumed + 1,
			    memory_order_acq_rel, memory_order_acquire)) {
				found = true;
				break;
			}
		}
		if (atomic_exchange_explicit(&race_flag[slot], 0, memory_order_acq_rel) != 0)
			found = true;
		if (!found)
			(void)erx_fiasco_park_wait(&race_group, &race_effects, NULL, slot, group, epoch,
			    race_clock_ns() + 50000);
	}
	return (NULL);
}

static int
run_race(void)
{
	pthread_t threads[RACE_EXECUTORS];

	for (uint32_t slot = 0; slot < RACE_EXECUTORS; slot++) {
		if (erx_fiasco_park_claim(&race_group, &race_effects, NULL) != slot)
			return (1);
		if (pthread_create(&threads[slot], NULL, race_executor, (void *)(uintptr_t)slot) != 0)
			return (1);
	}
	for (uint32_t round = 0; round < RACE_ROUNDS; round++) {
		const uint32_t slot = round % RACE_EXECUTORS;

		atomic_fetch_add_explicit(&race_published, 1, memory_order_acq_rel);
		erx_fiasco_park_trigger(&race_group, &race_effects, NULL);
		atomic_store_explicit(&race_flag[slot], 1, memory_order_release);
		if (erx_fiasco_park_wake(&race_group, &race_effects, NULL, slot) != ERX_OK)
			return (1);
	}
	while (atomic_load_explicit(&race_consumed, memory_order_acquire) != RACE_ROUNDS)
		sched_yield();
	atomic_store_explicit(&race_stop, 1, memory_order_release);
	for (uint32_t slot = 0; slot < RACE_EXECUTORS; slot++) {
		erx_fiasco_park_trigger(&race_group, &race_effects, NULL);
		pthread_join(threads[slot], NULL);
	}
	for (uint32_t slot = 0; slot < RACE_EXECUTORS; slot++)
		erx_fiasco_park_release(&race_group, &race_effects, NULL, slot);
	if (atomic_load_explicit(&race_status.parked, memory_order_relaxed) != 0 ||
	    atomic_load_explicit(&race_status.exec[0].state, memory_order_relaxed) != ERX_EXEC_STATE_NONE) {
		puts("race: the status page disagrees at the end");
		return (1);
	}
	printf("race: %u rounds\n", RACE_ROUNDS);
	return (0);
}

/* The refusals, and that the mirror follows the step. */
static int
run_calls(void)
{
	static erx_group_stat_t status;
	static erx_fiasco_park_group_t group = { .status = &status };
	const erx_fiasco_park_event_t bad_park = { .op = ERX_FIASCO_PARK_OP_PARK, .slot = 5 };
	uint32_t slot;

	if (erx_fiasco_park_wake(&group, &race_effects, NULL, 0) != ERX_EINVAL ||
	    erx_fiasco_park_wake(&group, &race_effects, NULL, ERX_GROUP_EXECUTORS_MAX) != ERX_EINVAL ||
	    erx_fiasco_park_step(&group.park, &bad_park).action != ERX_FIASCO_PARK_REFUSED) {
		puts("calls: an empty slot was not refused");
		return (1);
	}
	for (uint32_t index = 0; index < ERX_GROUP_EXECUTORS_MAX; index++) {
		slot = erx_fiasco_park_claim(&group, &race_effects, NULL);
		if (slot != index) {
			puts("calls: a claim did not take the lowest slot");
			return (1);
		}
	}
	if (erx_fiasco_park_claim(&group, &race_effects, NULL) != ERX_FIASCO_PARK_NO_SLOT) {
		puts("calls: a claim of a full group was not refused");
		return (1);
	}
	erx_fiasco_park_release(&group, &race_effects, NULL, 7);
	if (erx_fiasco_park_claim(&group, &race_effects, NULL) != 7 ||
	    atomic_load(&status.exec[7].state) != ERX_EXEC_STATE_RUNNING || atomic_load(&status.epoch) != 1) {
		puts("calls: a released slot did not return, or the mirror did not move");
		return (1);
	}
	if (erx_fiasco_park_wake(&group, &race_effects, NULL, 7) != ERX_OK || atomic_load(&status.exec[7].epoch) != 1) {
		puts("calls: a wake's epoch did not reach the mirror");
		return (1);
	}
	if (erx_fiasco_park_wait(&group, &race_effects, NULL, 7, 0, 1, UINT64_MAX) != ERX_OK) {
		puts("calls: a moved epoch did not return at once");
		return (1);
	}
/* Three parked: a wake takes the middle one, the order holds, a release and a trigger take the oldest. */
{
	erx_fiasco_park_t table = { .used = 15 };
	erx_fiasco_park_event_t event = { .op = ERX_FIASCO_PARK_OP_PARK };
	erx_fiasco_park_result_t result;

	for (event.slot = 0; event.slot < 3; event.slot++)
		(void)erx_fiasco_park_step(&table, &event);
	event.slot = 1;
	if (table.parked_count != 3 || erx_fiasco_park_step(&table, &event).action != ERX_FIASCO_PARK_REFUSED ||
	    table.parked_count != 3) {
		puts("calls: a slot parked twice");
		return (1);
	}
	event = (erx_fiasco_park_event_t){ .op = ERX_FIASCO_PARK_OP_WAKE, .slot = 1 };
	result = erx_fiasco_park_step(&table, &event);
	if (result.action != ERX_FIASCO_PARK_UP || result.slot != 1) {
		puts("calls: a wake did not take its slot");
		return (1);
	}
	event = (erx_fiasco_park_event_t){ .op = ERX_FIASCO_PARK_OP_RELEASE, .slot = 3 };
	result = erx_fiasco_park_step(&table, &event);
	if (result.action != ERX_FIASCO_PARK_UP || result.slot != 0) {
		puts("calls: a release did not wake the oldest");
		return (1);
	}
	event = (erx_fiasco_park_event_t){ .op = ERX_FIASCO_PARK_OP_TRIGGER };
	result = erx_fiasco_park_step(&table, &event);
	if (result.action != ERX_FIASCO_PARK_UP || result.slot != 2 || table.parked_count != 0) {
		puts("calls: the list lost its order");
		return (1);
	}
}
puts("calls: 1 pass");
	return (0);
}

int
main(int argc, char **argv)
{
	if (argc != 2)
		return (2);
	if (strcmp(argv[1], "exhaustive") == 0)
		return (run_exhaustive());
	if (strcmp(argv[1], "race") == 0)
		return (run_race());
	if (strcmp(argv[1], "calls") == 0)
		return (run_calls());
	return (2);
}
