/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The umtx calls and the park protocol's semaphores, over the host's wait on an
 * address. The host's own table holds the waiters, so its wake order is its own,
 * which is the one difference from the native table: a caller cannot count on the
 * oldest waiter first (docs/design-stopgap.md, "The hosted backend").
 */

#include <errno.h>
#include <os/clock.h>
#include <os/os_sync_wait_on_address.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <time.h>

#include "erx/abi.h"
#include "erx/core/effects.h"
#include "liberx/backend/api.h"
#include "liberx/backend/hosted/internal.h"

/* The host's wait until a wake or the deadline, whichever it reports first; false at the deadline. */
static bool
word_wait(_Atomic uint32_t *word, uint32_t expected, uint64_t deadline)
{
	for (;;) {
		int result;

		if (deadline == ERX_WAIT_FOREVER) {
			result = os_sync_wait_on_address(word, expected, sizeof(*word), OS_SYNC_WAIT_ON_ADDRESS_NONE);
		} else {
			const uint64_t now = erx_clock_ns();

			if (now >= deadline)
				return (false);
			result = os_sync_wait_on_address_with_timeout(word, expected, sizeof(*word),
			    OS_SYNC_WAIT_ON_ADDRESS_NONE, OS_CLOCK_MACH_ABSOLUTE_TIME, deadline - now);
		}
		if (result >= 0)
			return (true);
		if (errno != EINTR && errno != ETIMEDOUT)
			erx_hosted_fatal("erx: hosted: a wait on an address the host refused\n");
	}
}

uint64_t
erx_clock_ns(void)
{
	return (erx_effect_clock_ns());
}

int
erx_umtx_wait(uint64_t addr, uint32_t expected, uint64_t deadline)
{
	_Atomic uint32_t *const word = (_Atomic uint32_t *)(uintptr_t)addr;

	if (atomic_load_explicit(word, memory_order_acquire) != expected)
		return (ERX_OK);
	return (word_wait(word, expected, deadline) ? ERX_OK : ERX_ETIMEDOUT);
}

int
erx_umtx_wake(uint64_t addr, uint32_t count)
{
	void *const word = (void *)(uintptr_t)addr;
	int woken = 0;

	while ((uint32_t)woken < count && woken < INT32_MAX &&
	    os_sync_wake_by_address_any(word, sizeof(uint32_t), OS_SYNC_WAKE_BY_ADDRESS_NONE) == 0)
		woken++;
	return (woken);
}

void
erx_hosted_semaphore_up(_Atomic uint32_t *semaphore)
{
	atomic_fetch_add_explicit(semaphore, 1, memory_order_release);
	(void)os_sync_wake_by_address_any(semaphore, sizeof(*semaphore), OS_SYNC_WAKE_BY_ADDRESS_NONE);
}

bool
erx_hosted_semaphore_down(_Atomic uint32_t *semaphore, uint64_t deadline)
{
	for (;;) {
		uint32_t held = atomic_load_explicit(semaphore, memory_order_acquire);

		while (held != 0) {
			if (atomic_compare_exchange_weak_explicit(semaphore, &held, held - 1, memory_order_acquire,
			    memory_order_acquire))
				return (true);
		}
		if (!word_wait(semaphore, 0, deadline))
			return (false);
	}
}
