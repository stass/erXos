/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The task's park record (docs/design-stopgap.md, "Interrupts and readiness"): the
 * readiness of the task's home group, static data of which each task image has its own copy.
 * It holds the effects under park_table.c, which are the park lock and each executor's
 * semaphore, the one its umtx waits use, at 0 whenever its thread enters either wait;
 * each entry's label; the task's dispatcher; and the local take.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <l4/sys/ipc.h>
#include <l4/sys/semaphore.h>
#include <l4/sys/utcb.h>

#include "liberx/backend/api.h"
#include "liberx/backend/core/trace_ring.h"
#include "liberx/backend/fiasco/group.h"
#include "liberx/backend/fiasco/lock.h"
#include "liberx/backend/fiasco/park.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/umtx.h"

static void park_lock(void *);
static void park_unlock(void *);
static bool park_down(void *, uint32_t, uint64_t);
static void park_absorb(void *, uint32_t);
static void park_up(void *, uint32_t);
static void park_trace(void *, uint32_t, uint32_t, uint64_t);
static void dispatcher_main(uint64_t);

#define DISPATCHER_STACK_BYTES	16384u

static const erx_backend_park_effects_t park_effects = { .lock = park_lock, .unlock = park_unlock,
    .down = park_down, .absorb = park_absorb, .up = park_up, .trace = park_trace };
static _Alignas(ERX_PAGE_SIZE) erx_group_stat_t park_status;
static erx_backend_park_group_t park_group = { .status = &park_status };
static erx_fiasco_lock_t park_group_lock;
/* Which thread index runs in each slot, written by the claim before the thread starts. */
static _Atomic uint32_t park_slot_index[ERX_GROUP_EXECUTORS_MAX];
/*
 * Each entry's label, which a take reports. A bind writes it before it lets the object
 * fire, and a move changes the label a later take reads.
 */
static _Atomic uint64_t park_label[ERX_BACKEND_PARK_OBJECTS_MAX];
static _Alignas(16) uint8_t dispatcher_stack[DISPATCHER_STACK_BYTES];
static _Atomic bool dispatcher_started;

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

_Atomic uint64_t *
erx_fiasco_park_label(uint32_t entry)
{
	return (&park_label[entry]);
}

int
erx_group_take_ready(uint32_t max)
{
	erx_utcb_t *const utcb = erx_utcb_self();
	uint32_t objects[ERX_MSG_WORDS];
	uint32_t count;

	if (erx_fiasco_thread_self()->executor_slot == ERX_BACKEND_PARK_NO_SLOT)
		return (ERX_ETYPE);
	count = erx_fiasco_group_take(max < ERX_MSG_WORDS ? max : ERX_MSG_WORDS, objects);
	for (uint32_t index = 0; index < count; index++)
		atomic_store_explicit(&utcb->mr[index], atomic_load_explicit(&park_label[objects[index]], memory_order_acquire),
		    memory_order_relaxed);
	return ((int)count);
}

/*
 * Every message is one IRQ object firing, whose kernel label is its entry, and nothing
 * else holds a capability to this thread. The kernel keeps a second fire of an object
 * not yet received here as one delivery, which the listed flag would report as one anyway.
 */
static void
dispatcher_main(uint64_t unused)
{
	l4_utcb_t *const utcb = l4_utcb();
	l4_umword_t record;
	l4_msgtag_t tag;

	(void)unused;
	for (;;) {
		tag = l4_ipc_wait(utcb, &record, L4_IPC_NEVER);
		if (l4_ipc_error(tag, utcb) != 0)
			continue;
		/* Before the trigger, so the delivery precedes the wake it causes in the ring. */
		if (record < ERX_BACKEND_PARK_OBJECTS_MAX)
			erx_backend_trace_write(ERX_TRACE_EVENT_IRQ_DELIVER,
			    atomic_load_explicit(&park_label[record], memory_order_relaxed), 0, 0);
		erx_fiasco_group_signal((uint32_t)record);
	}
}

int
erx_fiasco_dispatcher_start(uint64_t group, uint64_t *thread)
{
	erx_fiasco_start_t start = { 0 };
	const uint64_t *const words = (const uint64_t *)(const void *)&start;
	erx_utcb_t *const utcb = erx_utcb_self();
	erx_fiasco_reply_t reply;
	int status;

	if (atomic_exchange_explicit(&dispatcher_started, true, memory_order_acq_rel))
		return (ERX_EINVAL);
	start.regs.sp = (uint64_t)(uintptr_t)(dispatcher_stack + sizeof(dispatcher_stack));
	start.regs.pc = (uint64_t)(uintptr_t)dispatcher_main;
	/* erx_thread_create takes the new thread's starting registers from the caller's UTCB. */
	for (size_t word = 0; word < sizeof(start) / sizeof(uint64_t); word++)
		atomic_store_explicit(&utcb->mr[word], words[word], memory_order_relaxed);
	status = erx_thread_create(0, 0, group, ERX_THREAD_CLASS_WORKER, thread);
	if (status != ERX_OK)
		return (status);
	status = erx_thread_start(*thread);
	if (status == ERX_OK) {
		const erx_fiasco_dispatcher_request_t request = { .caller = erx_fiasco_thread_self()->index, .thread = *thread };

		status = erx_fiasco_service_call(ERX_FIASCO_CALL_DISPATCHER_SET, &request, sizeof(request), &reply);
	}
	return (status);
}
