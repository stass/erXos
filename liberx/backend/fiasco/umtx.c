/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The effects under umtx_table.c: the table's lock and a thread's semaphore. A
 * wait is never early: see erx_fiasco_semaphore_down.
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

#ifdef ERX_FIASCO_TEST_HOOKS
/* The threads suite's counts of how its races came out. */
_Atomic uint64_t erx_fiasco_test_umtx_woken, erx_fiasco_test_umtx_timed_out, erx_fiasco_test_umtx_absorbed;
_Atomic uint64_t erx_fiasco_test_umtx_stale;
#endif

int
erx_umtx_wait(uint64_t addr, uint32_t expected, uint64_t deadline)
{
	erx_fiasco_umtx_node_t *const node = &erx_fiasco_thread_self()->node;
	const int status = erx_fiasco_umtx_wait(&umtx_table, &umtx_effects, NULL, node,
	    (const _Atomic uint32_t *)(uintptr_t)addr, expected, deadline);

#ifdef ERX_FIASCO_TEST_HOOKS
	/*
	 * A wait that returns with its node still queued was woken by no taker: the
	 * kernel's late activation of an earlier up (TODO.md, the semaphore's late wake).
	 */
	umtx_lock(NULL);
	if (node->queued)
		atomic_fetch_add_explicit(&erx_fiasco_test_umtx_stale, 1, memory_order_relaxed);
	umtx_unlock(NULL);
	atomic_fetch_add_explicit(status == ERX_OK ? &erx_fiasco_test_umtx_woken : &erx_fiasco_test_umtx_timed_out, 1,
	    memory_order_relaxed);
#endif
	return (status);
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
	(void)context;
	return (erx_fiasco_semaphore_down(umtx_semaphore(node), deadline));
}

static void
umtx_absorb(void *context, erx_fiasco_umtx_node_t *node)
{
	(void)context;
#ifdef ERX_FIASCO_TEST_HOOKS
	atomic_fetch_add_explicit(&erx_fiasco_test_umtx_absorbed, 1, memory_order_relaxed);
#endif
	(void)erx_fiasco_semaphore_down(umtx_semaphore(node), ERX_FIASCO_UMTX_FOREVER);
}

static void
umtx_up(void *context, erx_fiasco_umtx_node_t *node)
{
	(void)context;
	(void)l4_semaphore_up(umtx_semaphore(node));
}
