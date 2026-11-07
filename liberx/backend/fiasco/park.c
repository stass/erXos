/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The effects under park_table.c: the park lock and each executor's semaphore,
 * the one its umtx waits use, which is at 0 whenever its thread enters either wait.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include <l4/sys/semaphore.h>

#include "liberx/backend/core/trace_ring.h"
#include "liberx/backend/fiasco/lock.h"
#include "liberx/backend/fiasco/park.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/umtx.h"

static void park_lock(void *);
static void park_unlock(void *);
static bool park_down(void *, uint32_t, uint64_t);
static void park_absorb(void *, uint32_t);
static void park_up(void *, uint32_t);
static void park_trace(void *, uint32_t, uint32_t, uint64_t);

static const erx_backend_park_effects_t park_effects = { .lock = park_lock, .unlock = park_unlock,
    .down = park_down, .absorb = park_absorb, .up = park_up, .trace = park_trace };
static _Alignas(ERX_PAGE_SIZE) erx_group_stat_t park_status;
static erx_backend_park_group_t park_group = { .status = &park_status };
static erx_fiasco_lock_t park_group_lock;
/* Which thread index runs in each slot, written by the claim before the thread starts. */
static _Atomic uint32_t park_slot_index[ERX_GROUP_EXECUTORS_MAX];

static void
park_lock(void *context)
{
	(void)context;
	erx_fiasco_lock(&park_group_lock);
}

static void
park_unlock(void *context)
{
	(void)context;
	erx_fiasco_unlock(&park_group_lock);
}

static uint64_t
park_semaphore(uint32_t slot)
{
	return (erx_fiasco_thread_record(atomic_load_explicit(&park_slot_index[slot], memory_order_relaxed))->semaphore);
}

static bool
park_down(void *context, uint32_t slot, uint64_t deadline)
{
	(void)context;
	return (erx_fiasco_semaphore_down(park_semaphore(slot), deadline));
}

static void
park_absorb(void *context, uint32_t slot)
{
	(void)context;
	(void)erx_fiasco_semaphore_down(park_semaphore(slot), ERX_FIASCO_UMTX_FOREVER);
}

static void
park_up(void *context, uint32_t slot)
{
	(void)context;
	(void)l4_semaphore_up((l4_cap_idx_t)park_semaphore(slot));
}

/* The root records its executors' parks; a task's stub records nothing. */
static void
park_trace(void *context, uint32_t event, uint32_t slot, uint64_t arg)
{
	(void)context;
	erx_backend_trace_write(event, slot, arg, 0);
}

uint32_t
erx_fiasco_executor_claim(uint32_t index)
{
	const uint32_t slot = erx_backend_park_claim(&park_group, &park_effects, NULL);

	if (slot != ERX_BACKEND_PARK_NO_SLOT)
		atomic_store_explicit(&park_slot_index[slot], index, memory_order_relaxed);
	return (slot);
}

void
erx_fiasco_executor_release(uint32_t slot)
{
	erx_backend_park_release(&park_group, &park_effects, NULL, slot);
}

const erx_group_stat_t *
erx_fiasco_group_status(void)
{
	return (&park_status);
}

void
erx_fiasco_group_trigger(void)
{
	erx_backend_park_trigger(&park_group, &park_effects, NULL);
}

void
erx_fiasco_group_signal(uint32_t object)
{
	/* The dispatcher's label is an index of ours, so no refusal comes back. */
	(void)erx_backend_park_signal(&park_group, &park_effects, NULL, object);
}

uint32_t
erx_fiasco_group_take(uint32_t max, uint32_t *objects)
{
	return (erx_backend_park_take(&park_group, &park_effects, NULL, max, objects));
}

int
erx_park(uint64_t group_epoch, uint64_t slot_epoch, uint64_t deadline)
{
	const uint32_t slot = erx_fiasco_thread_self()->executor_slot;

	if (slot == ERX_BACKEND_PARK_NO_SLOT)
		return (ERX_ETYPE);
	return (erx_backend_park_wait(&park_group, &park_effects, NULL, slot, group_epoch, slot_epoch, deadline));
}

int
erx_executor_wake(uint32_t slot)
{
	return (erx_backend_park_wake(&park_group, &park_effects, NULL, slot));
}
