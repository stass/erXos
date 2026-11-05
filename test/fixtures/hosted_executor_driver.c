/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives erx_pthread_create_executor on the hosted backend: what an executor made this
 * way can do that a plain pthread cannot, what no free slot does, and that a slot comes
 * back after a return and after a pthread_exit. Prints one line per case, and test/host/
 * hosted_executor_test.rb reads them.
 */

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/pthread_executor.h"

#define ROUND_THREADS	ERX_GROUP_EXECUTORS_MAX
#define PARK_TIMEOUT_NS	UINT64_C(5000000)

typedef struct park_answer {
	uint32_t	slot;
	int		status;
} park_answer_t;

static _Atomic uint32_t release_word;

/* Parks with a deadline that passes: only an executor gets as far as the deadline. */
static void *
park_once(void *arg)
{
	park_answer_t *const answer = arg;
	const erx_group_stat_t *const status = erx_group_status();
	const uint32_t slot = erx_executor_slot();

	answer->slot = slot;
	answer->status = erx_park(atomic_load_explicit(&status->epoch, memory_order_acquire),
	    slot == ERX_NO_EXECUTOR_SLOT ? 0 : atomic_load_explicit(&status->exec[slot].epoch, memory_order_acquire),
	    erx_clock_ns() + PARK_TIMEOUT_NS);
	return (NULL);
}

static void *
returning_thread(void *arg)
{
	(void)arg;
	return (NULL);
}

static void *
exiting_thread(void *arg)
{
	(void)arg;
	pthread_exit(NULL);
}

static void *
liberx_exiting_thread(void *arg)
{
	(void)arg;
	erx_thread_exit();
	return (NULL);
}

/* Holds its slot until the round has filled the group. */
static void *
holding_thread(void *arg)
{
	void *(*const leave)(void *) = (void *(*)(void *))(uintptr_t)arg;

	while (atomic_load_explicit(&release_word, memory_order_acquire) == 0)
		(void)erx_umtx_wait((uint64_t)(uintptr_t)&release_word, 0, ERX_WAIT_FOREVER);
	return (leave(NULL));
}

/* The group's slots, all at once, then one more; every one is gone again on return. */
static bool
round_fills_then_refuses(void *(*leave)(void *))
{
	pthread_t threads[ROUND_THREADS];
	pthread_t spare;
	bool ok = true;

	atomic_store_explicit(&release_word, 0, memory_order_release);
	for (uint32_t index = 0; index < ROUND_THREADS; index++)
		ok = ok && erx_pthread_create_executor(&threads[index], NULL, holding_thread,
		    (void *)(uintptr_t)leave) == 0;
	ok = ok && erx_pthread_create_executor(&spare, NULL, returning_thread, NULL) == EAGAIN;
	atomic_store_explicit(&release_word, 1, memory_order_release);
	(void)erx_umtx_wake((uint64_t)(uintptr_t)&release_word, UINT32_MAX);
	for (uint32_t index = 0; index < ROUND_THREADS; index++)
		ok = ok && pthread_join(threads[index], NULL) == 0;
	return (ok);
}

static void
report(const char *name, bool ok)
{
	printf("%s: %s\n", name, ok ? "ok" : "FAILED");
}

int
main(void)
{
	pthread_t thread;
	park_answer_t answer = { 0 };
	pthread_attr_t attr;

	/* Line by line: a seeded driver may hang after a case, and what it printed still counts. */
	(void)setvbuf(stdout, NULL, _IOLBF, 0);
	report("an executor has a slot and parks to its deadline",
	    erx_pthread_create_executor(&thread, NULL, park_once, &answer) == 0 && pthread_join(thread, NULL) == 0 &&
	    answer.slot != ERX_NO_EXECUTOR_SLOT && answer.status == ERX_ETIMEDOUT);
	report("a plain pthread has no slot and may not park",
	    pthread_create(&thread, NULL, park_once, &answer) == 0 && pthread_join(thread, NULL) == 0 &&
	    answer.slot == ERX_NO_EXECUTOR_SLOT && answer.status == ERX_ETYPE);
	report("the creator's attributes are the thread's",
	    pthread_attr_init(&attr) == 0 && pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_JOINABLE) == 0 &&
	    erx_pthread_create_executor(&thread, &attr, returning_thread, NULL) == 0 &&
	    pthread_join(thread, NULL) == 0 && pthread_attr_destroy(&attr) == 0);
	report("slots return after a return", round_fills_then_refuses(returning_thread));
	report("slots return after a pthread_exit", round_fills_then_refuses(exiting_thread));
	report("slots return after erx_thread_exit", round_fills_then_refuses(liberx_exiting_thread));
	report("the group still fills", round_fills_then_refuses(returning_thread));
	return (0);
}
