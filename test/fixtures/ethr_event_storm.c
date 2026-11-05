/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * ethread's events over liberx's umtx, linked against the runtime's own libethread:
 * a timed wait that nothing sets times out and not early, and two threads pass a wake
 * back and forth while a timed waiter races each set. test/integration/
 * runtime_hosted_smoke_test.rb runs it with a deadline, so a lost wake is a hang the
 * deadline ends; a wake whose status the adapter gets wrong ends the program through
 * ethread's own fatal branch.
 */

#include <errno.h>
#include <stdint.h>
#include <stdio.h>

#include "ethread.h"
#include "liberx/backend/api.h"

#define ROUNDS		20000
#define TIMEOUT_NS	INT64_C(2000000)

static ethr_event ping;
static ethr_event pong;

/* The reply side: an executor, since events are what its class may wait on outside a park. */
static void *
reply_thread(void *arg)
{
	(void)arg;
	for (int round = 0; round < ROUNDS; round++) {
		int result;

		do {
			result = ethr_event_twait(&ping, TIMEOUT_NS);
		} while (result == ETIMEDOUT);
		if (result != 0) {
			printf("reply: wait said %d\n", result);
			return ((void *)(intptr_t)1);
		}
		/* Before the set: the next ping comes only after this pong. */
		ethr_event_reset(&ping);
		ethr_event_set(&pong);
	}
	return (NULL);
}

static int
timed_wait_times_out(void)
{
	const uint64_t started = erx_clock_ns();
	ethr_event alone;
	int result;

	if (ethr_event_init(&alone) != 0 || ethr_event_prepare_timed(&alone) != 0)
		return (-1);
	ethr_event_reset(&alone);
	result = ethr_event_twait(&alone, TIMEOUT_NS);
	return (result == ETIMEDOUT && erx_clock_ns() - started >= (uint64_t)TIMEOUT_NS ? 0 : -1);
}

int
main(void)
{
	ethr_thr_opts opts = ETHR_THR_OPTS_DEFAULT_INITER;
	ethr_tid tid;
	void *joined = NULL;

	opts.executor = 1;
	if (ethr_init(NULL) != 0 || ethr_late_init(NULL) != 0) {
		puts("ethread would not start");
		return (1);
	}
	if (timed_wait_times_out() != 0) {
		puts("a timed wait did not time out");
		return (1);
	}
	if (ethr_event_init(&ping) != 0 || ethr_event_prepare_timed(&ping) != 0 || ethr_event_init(&pong) != 0 ||
	    ethr_event_prepare_timed(&pong) != 0 || ethr_thr_create(&tid, reply_thread, NULL, &opts) != 0) {
		puts("the storm would not start");
		return (1);
	}
	for (int round = 0; round < ROUNDS; round++) {
		ethr_event_reset(&pong);
		ethr_event_set(&ping);
		if (ethr_event_wait(&pong) != 0) {
			puts("a wait failed");
			return (1);
		}
	}
	if (ethr_thr_join(tid, &joined) != 0 || joined != NULL) {
		puts("the reply side failed");
		return (1);
	}
	puts("storm done");
	return (0);
}
