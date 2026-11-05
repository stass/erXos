/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host checks of the umtx core, and the service decoder's refusals.
 *
 *   exhaustive  Every queue, cancel and take sequence over three waiters and three
 *               words, two of them in one bucket, against a model of plain lists.
 *   protocol    The wait and wake protocols with one thread and fake effects: a
 *               waker before the compare, a wake at the deadline, a plain timeout.
 *   race        Real threads under a real lock: turn by turn, with deadlines racing
 *               wakes. A semaphore holding an up when its thread enters a wait is a
 *               stale count, and a turn that never comes is a lost wake.
 *   wire        The decoder's refusals, one seeded message each.
 *
 * Prints what it covered and exits 0, or names the first disagreement and exits 1.
 */

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/service_wire.h"
#include "liberx/backend/fiasco/umtx_table.h"

#define WAITERS		3
#define WORDS		3
#define DEPTH		5
#define RACE_ROUNDS	20000u
#define RACE_PATIENCE_NS (UINT64_C(20) * 1000000000)

static _Noreturn void
fail(const char *what)
{
	printf("disagreement: %s\n", what);
	exit(1);
}

/* exhaustive */

static const uint64_t word_addrs[WORDS] = { 0x1000, 0x1000 + 4 * ERX_FIASCO_UMTX_BUCKETS, 0x1004 };

typedef struct model {
	erx_fiasco_umtx_table_t table;
	erx_fiasco_umtx_node_t nodes[WAITERS];
	int queue[WORDS][WAITERS];
	int length[WORDS];
	int word_of[WAITERS];		/* -1 when not queued */
} model_t;

static uint64_t sequences;

static void
model_remove(model_t *model, int word, int position)
{
	for (int index = position + 1; index < model->length[word]; index++)
		model->queue[word][index - 1] = model->queue[word][index];
	model->length[word]--;
}

/*
 * A plain walk over operation lists: each sequence replays from empty, so nothing
 * needs undoing and the table's pointers stay valid.
 */
static void
replay(const int *ops, int count)
{
	model_t model;

	memset(&model, 0, sizeof(model));
	for (int waiter = 0; waiter < WAITERS; waiter++)
		model.word_of[waiter] = -1;
	for (int step = 0; step < count; step++) {
		const int op = ops[step];

		if (op < WAITERS * WORDS) {
			const int waiter = op / WORDS, word = op % WORDS;

			if (model.word_of[waiter] >= 0)
				continue;
			erx_fiasco_umtx_queue(&model.table, &model.nodes[waiter], word_addrs[word]);
			model.queue[word][model.length[word]++] = waiter;
			model.word_of[waiter] = word;
		} else if (op < WAITERS * WORDS + WAITERS) {
			const int waiter = op - WAITERS * WORDS, word = model.word_of[waiter];

			if (erx_fiasco_umtx_cancel(&model.table, &model.nodes[waiter]) != (word >= 0))
				fail("cancel disagrees with the queue");
			if (word >= 0) {
				for (int position = 0; position < model.length[word]; position++)
					if (model.queue[word][position] == waiter) {
						model_remove(&model, word, position);
						break;
					}
				model.word_of[waiter] = -1;
			}
		} else {
			const int rest = op - WAITERS * WORDS - WAITERS;
			const int word = rest / WAITERS;
			const uint32_t want = (uint32_t)(rest % WAITERS) + 1;
			erx_fiasco_umtx_node_t *node = erx_fiasco_umtx_take(&model.table, word_addrs[word], want);
			uint32_t expected = want < (uint32_t)model.length[word] ? want : (uint32_t)model.length[word];

			for (uint32_t index = 0; index < expected; index++) {
				const int waiter = model.queue[word][0];

				if (node != &model.nodes[waiter])
					fail("a take is not oldest first");
				if (node->queued)
					fail("a taken node still reads queued");
				node = node->next;
				model_remove(&model, word, 0);
				model.word_of[waiter] = -1;
			}
			if (node != NULL)
				fail("a take took more than asked");
		}
	}
}

static void
walk(int *ops, int count)
{
	const int kinds = WAITERS * WORDS + WAITERS + WORDS * WAITERS;

	replay(ops, count);
	sequences++;
	if (count == DEPTH)
		return;
	for (int op = 0; op < kinds; op++) {
		ops[count] = op;
		walk(ops, count + 1);
	}
}

static void
run_exhaustive(void)
{
	int ops[DEPTH];

	walk(ops, 0);
	printf("exhaustive: %llu sequences\n", (unsigned long long)sequences);
}

/* protocol */

typedef struct fake {
	erx_fiasco_umtx_table_t table;
	erx_fiasco_umtx_node_t node;
	_Atomic uint32_t value;
	int semaphore;
	int downs;
	int absorbs;
	bool locked;
	bool waker_before_compare;
	bool waker_at_deadline;
} fake_t;

static const erx_fiasco_umtx_effects_t fake_effects;

static void
fake_waker(fake_t *fake)
{
	atomic_store(&fake->value, atomic_load(&fake->value) + 1);
	(void)erx_fiasco_umtx_wake(&fake->table, &fake_effects, fake, &fake->value, 1);
}

static void
fake_lock(void *context)
{
	fake_t *const fake = context;

	if (fake->waker_before_compare) {
		fake->waker_before_compare = false;
		fake_waker(fake);
	}
	if (fake->locked)
		fail("the lock is taken twice");
	fake->locked = true;
}

static void
fake_unlock(void *context)
{
	((fake_t *)context)->locked = false;
}

static bool
fake_down(void *context, erx_fiasco_umtx_node_t *node, uint64_t deadline)
{
	fake_t *const fake = context;

	(void)node;
	(void)deadline;
	if (fake->locked)
		fail("down runs under the lock");
	fake->downs++;
	if (fake->waker_at_deadline) {
		fake->waker_at_deadline = false;
		fake_waker(fake);
		return (false);
	}
	if (fake->semaphore > 0) {
		fake->semaphore--;
		return (true);
	}
	return (false);
}

static void
fake_absorb(void *context, erx_fiasco_umtx_node_t *node)
{
	fake_t *const fake = context;

	(void)node;
	if (fake->semaphore == 0)
		fail("an absorb with no up owed would hang");
	fake->semaphore--;
	fake->absorbs++;
}

static void
fake_up(void *context, erx_fiasco_umtx_node_t *node)
{
	fake_t *const fake = context;

	(void)node;
	if (fake->locked)
		fail("up runs under the lock");
	fake->semaphore++;
}

static const erx_fiasco_umtx_effects_t fake_effects = { .lock = fake_lock, .unlock = fake_unlock,
    .down = fake_down, .absorb = fake_absorb, .up = fake_up };

static int
fake_wait(fake_t *fake)
{
	return (erx_fiasco_umtx_wait(&fake->table, &fake_effects, fake, &fake->node, &fake->value,
	    atomic_load(&fake->value), 0));
}

static void
run_protocol(void)
{
	fake_t fake;

	memset(&fake, 0, sizeof(fake));
	atomic_store(&fake.value, 1);
	if (erx_fiasco_umtx_wait(&fake.table, &fake_effects, &fake, &fake.node, &fake.value, 0, 0) != ERX_OK ||
	    fake.downs != 0 || fake.node.queued)
		fail("a word that differs must return at once");

	memset(&fake, 0, sizeof(fake));
	if (fake_wait(&fake) != ERX_ETIMEDOUT || fake.node.queued || fake.absorbs != 0)
		fail("a plain timeout must leave the queue and absorb nothing");

	memset(&fake, 0, sizeof(fake));
	fake.waker_at_deadline = true;
	if (fake_wait(&fake) != ERX_OK)
		fail("a wake at the deadline must count as a wake");
	if (fake.semaphore != 0)
		fail("stale count: the up of a wake at the deadline stays in the semaphore");

	memset(&fake, 0, sizeof(fake));
	fake.waker_before_compare = true;
	{
		const uint32_t seen = atomic_load(&fake.value);

		if (erx_fiasco_umtx_wait(&fake.table, &fake_effects, &fake, &fake.node, &fake.value, seen, 0) != ERX_OK)
			fail("lost wake: a store and wake before the compare left the thread queued");
	}
	printf("protocol: 4 cases\n");
}

/* race */

typedef struct real_semaphore {
	pthread_mutex_t mutex;
	pthread_cond_t	cond;
	int		count;
} real_semaphore_t;

typedef struct real_thread {
	erx_fiasco_umtx_node_t node;
	real_semaphore_t semaphore;
} real_thread_t;

static erx_fiasco_umtx_table_t real_table;
static pthread_mutex_t real_lock_mutex = PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint32_t real_turn;
static _Atomic uint32_t real_racing;
static _Atomic uint32_t real_stop;

static uint64_t
now_ns(void)
{
	struct timespec now;

	clock_gettime(CLOCK_REALTIME, &now);
	return ((uint64_t)now.tv_sec * 1000000000 + (uint64_t)now.tv_nsec);
}

static void
real_lock(void *context)
{
	(void)context;
	pthread_mutex_lock(&real_lock_mutex);
}

static void
real_unlock(void *context)
{
	(void)context;
	pthread_mutex_unlock(&real_lock_mutex);
}

static real_thread_t *
real_of(erx_fiasco_umtx_node_t *node)
{
	return ((real_thread_t *)(void *)node);
}

static bool
real_down(void *context, erx_fiasco_umtx_node_t *node, uint64_t deadline)
{
	real_semaphore_t *const semaphore = &real_of(node)->semaphore;
	struct timespec until = { .tv_sec = (time_t)(deadline / 1000000000), .tv_nsec = (long)(deadline % 1000000000) };
	bool got = true;

	(void)context;
	pthread_mutex_lock(&semaphore->mutex);
	while (semaphore->count == 0 && got)
		got = pthread_cond_timedwait(&semaphore->cond, &semaphore->mutex, &until) == 0;
	if (semaphore->count > 0) {
		semaphore->count--;
		got = true;
	}
	pthread_mutex_unlock(&semaphore->mutex);
	return (got);
}

static void
real_absorb(void *context, erx_fiasco_umtx_node_t *node)
{
	real_semaphore_t *const semaphore = &real_of(node)->semaphore;

	(void)context;
	pthread_mutex_lock(&semaphore->mutex);
	while (semaphore->count == 0)
		pthread_cond_wait(&semaphore->cond, &semaphore->mutex);
	semaphore->count--;
	pthread_mutex_unlock(&semaphore->mutex);
}

static void
real_up(void *context, erx_fiasco_umtx_node_t *node)
{
	real_semaphore_t *const semaphore = &real_of(node)->semaphore;

	(void)context;
	pthread_mutex_lock(&semaphore->mutex);
	semaphore->count++;
	pthread_cond_signal(&semaphore->cond);
	pthread_mutex_unlock(&semaphore->mutex);
}

static const erx_fiasco_umtx_effects_t real_effects = { .lock = real_lock, .unlock = real_unlock,
    .down = real_down, .absorb = real_absorb, .up = real_up };

static void
real_init(real_thread_t *thread)
{
	memset(thread, 0, sizeof(*thread));
	pthread_mutex_init(&thread->semaphore.mutex, NULL);
	pthread_cond_init(&thread->semaphore.cond, NULL);
}

static int
real_wait(real_thread_t *thread, const _Atomic uint32_t *word, uint32_t expected, uint64_t deadline)
{
	pthread_mutex_lock(&thread->semaphore.mutex);
	if (thread->semaphore.count != 0)
		fail("stale count: a semaphore holds an up as its thread enters a wait");
	pthread_mutex_unlock(&thread->semaphore.mutex);
	return (erx_fiasco_umtx_wait(&real_table, &real_effects, NULL, &thread->node, word, expected, deadline));
}

static void *
real_turns(void *argument)
{
	const uint32_t mine = (uint32_t)(uintptr_t)argument;
	real_thread_t self;

	real_init(&self);
	for (uint32_t round = 0; round < RACE_ROUNDS; round++) {
		while (atomic_load_explicit(&real_turn, memory_order_acquire) != mine) {
			if (real_wait(&self, &real_turn, 1 - mine, now_ns() + RACE_PATIENCE_NS) == ERX_ETIMEDOUT &&
			    atomic_load(&real_turn) != mine)
				fail("lost wake: a turn never came");
		}
		atomic_store_explicit(&real_turn, 1 - mine, memory_order_release);
		(void)erx_fiasco_umtx_wake(&real_table, &real_effects, NULL, &real_turn, 1);
	}
	return (NULL);
}

static void *
real_short_waits(void *argument)
{
	real_thread_t self;

	(void)argument;
	real_init(&self);
	for (uint32_t round = 0; round < RACE_ROUNDS; round++)
		(void)real_wait(&self, &real_racing, 0, now_ns() + (round % 16) * 1000);
	atomic_store(&real_stop, 1);
	return (NULL);
}

static void *
real_wakes(void *argument)
{
	(void)argument;
	while (atomic_load_explicit(&real_stop, memory_order_acquire) == 0)
		(void)erx_fiasco_umtx_wake(&real_table, &real_effects, NULL, &real_racing, 1);
	return (NULL);
}

static void
run_race(void)
{
	pthread_t threads[4];

	pthread_create(&threads[0], NULL, real_turns, (void *)(uintptr_t)0);
	pthread_create(&threads[1], NULL, real_turns, (void *)(uintptr_t)1);
	pthread_create(&threads[2], NULL, real_short_waits, NULL);
	pthread_create(&threads[3], NULL, real_wakes, NULL);
	for (size_t index = 0; index < 4; index++)
		pthread_join(threads[index], NULL);
	printf("race: %u rounds\n", RACE_ROUNDS);
}

/* wire */

static erx_fiasco_wire_decoded_t
decode(uint64_t label, int64_t tag_label, uint32_t words, uint64_t caller)
{
	uint64_t mr[63] = { caller, 7, 8, 9, 10, 11 };
	const erx_fiasco_wire_input_t input = { .label = label, .tag_label = tag_label, .words = words,
	    .live_mask = 1, .mr = mr };

	return (erx_fiasco_wire_decode(&input));
}

static void
run_wire(void)
{
	const uint32_t start_words = sizeof(erx_fiasco_thread_start_request_t) / sizeof(uint64_t);
	erx_fiasco_wire_decoded_t got;

	if (decode(1u << ERX_FIASCO_WIRE_LABEL_SHIFT, ERX_FIASCO_CALL_THREAD_START, start_words, 0).kind != ERX_FIASCO_WIRE_DROP)
		fail("a label naming no live task must drop");
	if (decode(3, ERX_FIASCO_WIRE_PAGE_FAULT, 2, 0).kind != ERX_FIASCO_WIRE_FAULT_PAGE)
		fail("the sender's rights in a label must be masked");
	if (decode(0, ERX_FIASCO_WIRE_EXCEPTION, ERX_FIASCO_WIRE_EXCEPTION_WORDS, 0).kind != ERX_FIASCO_WIRE_FAULT_EXCEPTION)
		fail("an exception is a fault");
	/* A fault's handler reads its fields without looking again, so a short message must not get there. */
	for (uint32_t words = 0; words < 64; words++) {
		if (words != ERX_FIASCO_WIRE_PAGE_FAULT_WORDS && decode(0, ERX_FIASCO_WIRE_PAGE_FAULT, words, 0).kind != ERX_FIASCO_WIRE_REFUSE)
			fail("a page fault of any other length is refused");
		if (words != ERX_FIASCO_WIRE_EXCEPTION_WORDS && decode(0, ERX_FIASCO_WIRE_EXCEPTION, words, 0).kind != ERX_FIASCO_WIRE_REFUSE)
			fail("an exception of any other length is refused");
	}
	got = decode(0, 200, start_words, 0);
	if (got.kind != ERX_FIASCO_WIRE_REFUSE || got.status != ERX_EINVAL)
		fail("an unknown number is ERX_EINVAL");
	got = decode(0, -1, start_words, 0);
	if (got.kind != ERX_FIASCO_WIRE_REFUSE || got.status != ERX_EINVAL)
		fail("an unknown negative number is ERX_EINVAL");
	got = decode(0, ERX_CALL_DEBUG_LOG, 1, 0);
	if (got.kind != ERX_FIASCO_WIRE_REFUSE || got.status != ERX_EINVAL)
		fail("a debug log of any other word count is ERX_EINVAL");
	got = decode(0, ERX_FIASCO_CALL_THREAD_START, start_words + 1, 0);
	if (got.kind != ERX_FIASCO_WIRE_REFUSE || got.status != ERX_EINVAL)
		fail("a word count the ABI does not give is ERX_EINVAL");
	got = decode(0, ERX_FIASCO_CALL_THREAD_START, start_words, ERX_FIASCO_THREADS_MAX);
	if (got.kind != ERX_FIASCO_WIRE_REFUSE || got.status != ERX_EINVAL)
		fail("a thread index past the table is ERX_EINVAL");
	got = decode(0, ERX_FIASCO_CALL_THREAD_START, start_words, ERX_FIASCO_THREADS_MAX - 1);
	if (got.kind != ERX_FIASCO_WIRE_REQUEST || got.caller != ERX_FIASCO_THREADS_MAX - 1 || got.request[1] != 7)
		fail("a good request must decode");
	printf("wire: 11 cases\n");
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
	else if (strcmp(mode, "wire") == 0)
		run_wire();
	else
		fail("no such mode");
	return (0);
}
