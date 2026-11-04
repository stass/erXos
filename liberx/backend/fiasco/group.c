/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The caller's half of interrupts and readiness: the group's dispatcher, which turns
 * each IRQ delivery into a signal of the park core, the labels of the objects bound
 * to the group, and the stubs of the calls whose bodies the service runs.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <l4/sys/ipc.h>
#include <l4/sys/utcb.h>

#include "liberx/backend/fiasco/group.h"
#include "liberx/backend/fiasco/lock.h"
#include "liberx/backend/fiasco/park.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/thread.h"

#define GROUP_HANDLE		UINT64_C(1)
#define DISPATCHER_STACK_BYTES	16384u

static void	dispatcher_main(uint64_t);

static _Alignas(16) uint8_t dispatcher_stack[DISPATCHER_STACK_BYTES];
/* Whether a create has begun; group_up says it finished. */
static _Atomic bool group_created;
static _Atomic bool group_up;
/* The dispatcher's index: written before group_up's release, read after its acquire. */
static uint64_t group_dispatcher;
/* Guards the claim of a record. A record's label is written before its object can fire. */
static erx_fiasco_lock_t group_lock;
static bool group_record_used[ERX_BACKEND_PARK_OBJECTS_MAX];
static uint64_t group_label[ERX_BACKEND_PARK_OBJECTS_MAX];

/*
 * Every message is one IRQ object firing, whose kernel label is its record's index,
 * and nothing else holds a capability to this thread. The kernel keeps a second fire
 * of an object not yet received here as one delivery, which the listed flag would
 * report as one anyway.
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
		if (l4_ipc_error(tag, utcb) == 0)
			erx_fiasco_group_signal((uint32_t)record);
	}
}

int
erx_group_create(uint64_t budget, uint64_t parent, uint64_t *group)
{
	erx_fiasco_start_t start = { 0 };
	const uint64_t *const words = (const uint64_t *)(const void *)&start;
	erx_utcb_t *const utcb = erx_utcb_self();
	uint64_t thread;
	int status;

	(void)budget;
	(void)parent;
	if (atomic_exchange_explicit(&group_created, true, memory_order_acq_rel))
		return (ERX_ELIMIT);
	start.regs.sp = (uint64_t)(uintptr_t)(dispatcher_stack + sizeof(dispatcher_stack));
	start.regs.pc = (uint64_t)(uintptr_t)dispatcher_main;
	/* erx_thread_create takes the new thread's starting registers from the caller's UTCB. */
	for (size_t word = 0; word < sizeof(start) / sizeof(uint64_t); word++)
		atomic_store_explicit(&utcb->mr[word], words[word], memory_order_relaxed);
	status = erx_thread_create(0, 0, 0, ERX_THREAD_CLASS_WORKER, &thread);
	if (status == ERX_OK)
		status = erx_thread_start(thread);
	if (status != ERX_OK) {
		atomic_store_explicit(&group_created, false, memory_order_release);
		return (status);
	}
	group_dispatcher = thread;
	atomic_store_explicit(&group_up, true, memory_order_release);
	*group = GROUP_HANDLE;
	return (ERX_OK);
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
		atomic_store_explicit(&utcb->mr[index], group_label[objects[index]], memory_order_relaxed);
	return ((int)count);
}

int
erx_irq_create(uint64_t budget, uint64_t resource, uint64_t kind, uint64_t selector, uint64_t *irq)
{
	const erx_fiasco_irq_create_request_t request = { .caller = erx_fiasco_thread_self()->index,
	    .kind = kind, .selector = selector };
	erx_fiasco_reply_t reply;
	int status;

	(void)budget;
	(void)resource;
	status = erx_fiasco_service_call(ERX_FIASCO_CALL_IRQ_CREATE, &request, sizeof(request), &reply);
	if (status == ERX_OK)
		*irq = reply.first;
	return (status);
}

/* Returns ERX_BACKEND_PARK_OBJECTS_MAX when every record is taken. */
static uint32_t
group_record_claim(void)
{
	uint32_t record = 0;

	erx_fiasco_lock(&group_lock);
	while (record < ERX_BACKEND_PARK_OBJECTS_MAX && group_record_used[record])
		record++;
	if (record < ERX_BACKEND_PARK_OBJECTS_MAX)
		group_record_used[record] = true;
	erx_fiasco_unlock(&group_lock);
	return (record);
}

int
erx_irq_bind(uint64_t irq, uint64_t group, uint64_t label)
{
	erx_fiasco_reply_t reply;
	uint32_t record;
	int status;

	if (group != GROUP_HANDLE || !atomic_load_explicit(&group_up, memory_order_acquire))
		return (ERX_EINVAL);
	record = group_record_claim();
	if (record == ERX_BACKEND_PARK_OBJECTS_MAX)
		return (ERX_ENOMEM);
	group_label[record] = label;

	const erx_fiasco_irq_bind_request_t request = { .caller = erx_fiasco_thread_self()->index,
	    .irq = irq, .thread = group_dispatcher, .record = record };

	status = erx_fiasco_service_call(ERX_FIASCO_CALL_IRQ_BIND, &request, sizeof(request), &reply);
	if (status != ERX_OK) {
		erx_fiasco_lock(&group_lock);
		group_record_used[record] = false;
		erx_fiasco_unlock(&group_lock);
	}
	return (status);
}

int
erx_irq_ack(uint64_t irq)
{
	const erx_fiasco_irq_request_t request = { .caller = erx_fiasco_thread_self()->index, .irq = irq };
	erx_fiasco_reply_t reply;

	return (erx_fiasco_service_call(ERX_FIASCO_CALL_IRQ_ACK, &request, sizeof(request), &reply));
}

int
erx_irq_trigger(uint64_t irq)
{
	const erx_fiasco_irq_request_t request = { .caller = erx_fiasco_thread_self()->index, .irq = irq };
	erx_fiasco_reply_t reply;

	return (erx_fiasco_service_call(ERX_FIASCO_CALL_IRQ_TRIGGER, &request, sizeof(request), &reply));
}
