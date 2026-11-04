/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The effects under umtx_table.c: the table's lock and a thread's semaphore. A
 * wait is never early: the remainder rounds up to microseconds, the kernel's
 * timeout rounds up again, and a timer that fires early, or a remainder past the
 * longest timeout, only waits again.
 */

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#include <l4/sys/ipc.h>
#include <l4/sys/semaphore.h>
#include <l4/sys/utcb.h>

#include "liberx/backend/fiasco/lock.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/umtx.h"

#define UMTX_NS_PER_US	UINT64_C(1000)

static void umtx_lock(void *);
static void umtx_unlock(void *);
static bool umtx_down(void *, erx_fiasco_umtx_node_t *, uint64_t);
static void umtx_absorb(void *, erx_fiasco_umtx_node_t *);
static void umtx_up(void *, erx_fiasco_umtx_node_t *);
static l4_cap_idx_t umtx_semaphore(const erx_fiasco_umtx_node_t *);

static const erx_fiasco_umtx_effects_t umtx_effects = { .lock = umtx_lock, .unlock = umtx_unlock,
    .down = umtx_down, .absorb = umtx_absorb, .up = umtx_up };
static erx_fiasco_umtx_table_t umtx_table;
static erx_fiasco_lock_t umtx_table_lock;

int
erx_umtx_wait(uint64_t addr, uint32_t expected, uint64_t deadline)
{
	return (erx_fiasco_umtx_wait(&umtx_table, &umtx_effects, NULL, &erx_fiasco_thread_self()->node,
	    (const _Atomic uint32_t *)(uintptr_t)addr, expected, deadline));
}

int
erx_umtx_wake(uint64_t addr, uint32_t count)
{
	return ((int)erx_fiasco_umtx_wake(&umtx_table, &umtx_effects, NULL,
	    (const _Atomic uint32_t *)(uintptr_t)addr, count));
}

static void
umtx_lock(void *context)
{
	(void)context;
	erx_fiasco_lock(&umtx_table_lock);
}

static void
umtx_unlock(void *context)
{
	(void)context;
	erx_fiasco_unlock(&umtx_table_lock);
}

static l4_cap_idx_t
umtx_semaphore(const erx_fiasco_umtx_node_t *node)
{
	return ((l4_cap_idx_t)((const erx_fiasco_thread_record_t *)(const void *)
	    ((const char *)node - offsetof(erx_fiasco_thread_record_t, node)))->semaphore);
}

static bool
umtx_down(void *context, erx_fiasco_umtx_node_t *node, uint64_t deadline)
{
	const l4_cap_idx_t semaphore = umtx_semaphore(node);
	l4_timeout_t timeout = L4_IPC_NEVER;
	uint64_t now, remainder;
	l4_msgtag_t tag;

	(void)context;
	for (;;) {
		if (deadline != ERX_FIASCO_UMTX_FOREVER) {
			now = erx_fiasco_clock_ns();
			if (now >= deadline)
				return (false);
			remainder = (deadline - now - 1) / UMTX_NS_PER_US + 1;
			timeout = l4_timeout(L4_IPC_TIMEOUT_NEVER, l4_timeout_from_us(
			    remainder < L4_TIMEOUT_US_MAX ? remainder : L4_TIMEOUT_US_MAX));
		}
		tag = l4_semaphore_down(semaphore, timeout);
		if (l4_ipc_error(tag, l4_utcb()) == 0)
			return (true);
	}
}

static void
umtx_absorb(void *context, erx_fiasco_umtx_node_t *node)
{
	(void)context;
	while (l4_ipc_error(l4_semaphore_down(umtx_semaphore(node), L4_IPC_NEVER), l4_utcb()) != 0)
		continue;
}

static void
umtx_up(void *context, erx_fiasco_umtx_node_t *node)
{
	(void)context;
	(void)l4_semaphore_up(umtx_semaphore(node));
}
