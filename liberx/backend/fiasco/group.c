/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Groups as records (docs/design-stopgap.md, "Budgets and groups as records"): the
 * service's group records and their homes, and the root's stubs of the group and IRQ
 * calls. A group record is an object record of kind group in the root's handle table.
 * Its home, the one task its threads run in, is that task's row (service_task.h), which
 * the group's first thread sets; a task is the home of one group at most. The home's
 * park record (park.c) holds the group's readiness and the dispatcher that triggers it.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "liberx/backend/api.h"
#include "liberx/backend/core/group_report.h"
#include "liberx/backend/core/handles.h"
#include "liberx/backend/core/object_info.h"
#include "liberx/backend/fiasco/group.h"
#include "liberx/backend/fiasco/object.h"
#include "liberx/backend/fiasco/park.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/thread.h"

static int	group_fill(uint32_t, const void *);

/* Whether the root's first create has begun; group_up says it finished. */
static _Atomic bool group_created;
static _Atomic bool group_up;
/* The root's own group: written before group_up's release, read after its acquire. */
static uint64_t group_root;
static _Atomic uint64_t group_cpuset;

/* A group record holds nothing beyond its object record: its home is its home task's row. */
static int
group_fill(uint32_t index, const void *request)
{
	(void)index;
	(void)request;
	return (ERX_OK);
}

/* Only the root makes a group, as only the domain library does in Phase 1. */
int
erx_fiasco_group_create_body(uint32_t task, uint64_t budget, uint64_t *group)
{
	if (task != ERX_FIASCO_TASK_ROOT)
		return (ERX_ENOTSUP);
	return (erx_fiasco_object_create(task, ERX_BACKEND_OBJECT_GROUP, budget, group_fill, NULL, group));
}

int
erx_fiasco_group_admit(uint32_t caller, uint32_t task, uint64_t group, uint32_t *record)
{
	uint32_t index, home;
	int status;

	*record = ERX_FIASCO_GROUP_NONE;
	if (group == ERX_CAP_NULL)
		return (ERX_OK);
	status = erx_fiasco_object_find(caller, group, ERX_BACKEND_OBJECT_GROUP, &index);
	if (status != ERX_OK)
		return (status);
	if (erx_fiasco_task_group_home(index, &home)) {
		/* Every thread of a group runs in its home. */
		if (home != task)
			return (ERX_ENOTSUP);
	} else if (erx_fiasco_task(task)->group != 0) {
		/* A homeless group would be the task's second home group. */
		return (ERX_ENOTSUP);
	}
	*record = index;
	return (ERX_OK);
}

void
erx_fiasco_group_join(uint32_t task, uint32_t record)
{
	if (record == ERX_FIASCO_GROUP_NONE)
		return;
	erx_fiasco_task(task)->group = record + 1;
	erx_fiasco_irq_group_ready(record);
}

bool
erx_fiasco_group_home_has_threads(uint32_t record)
{
	uint64_t threads[2];
	uint32_t home;

	if (!erx_fiasco_task_group_home(record, &home))
		return (false);
	erx_fiasco_task_thread_map(home, threads);
	return ((threads[0] | threads[1]) != 0);
}

void
erx_fiasco_group_free(uint32_t record)
{
	uint32_t home;

	erx_fiasco_irq_group_end(record);
	if (erx_fiasco_task_group_home(record, &home))
		erx_fiasco_task(home)->group = 0;
}

/*
 * The thread is one of the task's own, created and not reaped; a task names one
 * dispatcher, which receives every IRQ object bound to its home group (irq.c).
 */
int
erx_fiasco_dispatcher_set_body(uint32_t task, uint64_t thread)
{
	erx_fiasco_task_t *const row = erx_fiasco_task(task);

	if (thread >= ERX_FIASCO_THREADS_MAX || row->threads[thread] == ERX_FIASCO_TASK_THREAD_ABSENT || row->dispatcher != 0)
		return (ERX_EINVAL);
	row->dispatcher = (uint32_t)thread + 1;
	if (row->group != 0)
		erx_fiasco_irq_group_ready(row->group - 1);
	return (ERX_OK);
}

/*
 * The root's first group is its own: the root's dispatcher, started here, is the first
 * thread created in it, which makes the root its home. Every later group waits for the
 * first thread of the task it was made for, so a root thread that names a homeless
 * group before this call takes the root's home. parent is ignored: a recorded difference.
 * A failed dispatcher start may leave its thread, so the first create is never retried:
 * the record goes when it is homeless, and the root then has no group of its own.
 */
int
erx_group_create(uint64_t budget, uint64_t parent, uint64_t *group)
{
	const erx_fiasco_group_create_request_t request = { .caller = erx_fiasco_thread_self()->index, .budget = budget };
	erx_fiasco_reply_t reply;
	uint64_t thread;
	int status;

	(void)parent;
	status = erx_fiasco_service_call(ERX_FIASCO_CALL_GROUP_CREATE, &request, sizeof(request), &reply);
	if (status != ERX_OK)
		return (status);
	if (!atomic_exchange_explicit(&group_created, true, memory_order_acq_rel)) {
		status = erx_fiasco_dispatcher_start(reply.first, &thread);
		if (status != ERX_OK) {
			(void)erx_object_destroy(reply.first);
			return (status);
		}
		group_root = reply.first;
		atomic_store_explicit(&group_up, true, memory_order_release);
	}
	*group = reply.first;
	return (ERX_OK);
}

/* Whether the handle names the root's own group: ERX_CAP_SELF, or what its first create gave. */
static bool
group_is_root(uint64_t group)
{
	return (atomic_load_explicit(&group_up, memory_order_acquire) && (group == group_root || group == ERX_CAP_SELF));
}

int
erx_group_configure(uint64_t group)
{
	if (!group_is_root(group))
		return (ERX_EINVAL);
	return (erx_backend_group_configure(erx_utcb_self(), &group_cpuset));
}

int
erx_group_info(uint64_t group)
{
	if (!group_is_root(group))
		return (ERX_EINVAL);
	erx_backend_group_report(erx_utcb_self(), erx_fiasco_group_status(), &group_cpuset);
	return (ERX_OK);
}

int
erx_irq_create(uint64_t budget, uint64_t resource, uint32_t kind, uint64_t selector, uint64_t *irq)
{
	const erx_fiasco_irq_create_request_t request = { .caller = erx_fiasco_thread_self()->index,
	    .kind = kind, .selector = selector, .budget = budget };
	erx_fiasco_reply_t reply;
	int status;

	(void)resource;
	status = erx_fiasco_service_call(ERX_FIASCO_CALL_IRQ_CREATE, &request, sizeof(request), &reply);
	if (status == ERX_OK)
		*irq = reply.first;
	return (status);
}

/* ERX_CAP_NULL unbinds; the service keeps every bind and writes each label (irq.c). */
int
erx_irq_bind(uint64_t irq, uint64_t group, uint64_t label)
{
	erx_fiasco_reply_t reply;

	if (group == ERX_CAP_NULL) {
		const erx_fiasco_irq_request_t request = { .caller = erx_fiasco_thread_self()->index, .irq = irq };

		return (erx_fiasco_service_call(ERX_FIASCO_CALL_IRQ_UNBIND, &request, sizeof(request), &reply));
	}

	const erx_fiasco_irq_bind_request_t request = { .caller = erx_fiasco_thread_self()->index,
	    .irq = irq, .group = group, .label = label };

	return (erx_fiasco_service_call(ERX_FIASCO_CALL_IRQ_BIND, &request, sizeof(request), &reply));
}

/*
 * Group runs erx_group_info's local body; every other topic is the service's
 * (docs/design-stopgap.md, "Reporting kernel objects"). Only the root links it, as
 * every topic is the root's alone.
 */
int
erx_object_info(uint64_t object, uint32_t topic, uint64_t index, void *window, uint64_t size)
{
	const erx_fiasco_object_info_request_t request = { .caller = erx_fiasco_thread_self()->index,
	    .object = object, .topic = topic, .index = index, .window = (uint64_t)(uintptr_t)window, .size = size };
	erx_fiasco_reply_t reply;
	erx_info_facts_t facts = { 0 };

	if (topic != ERX_INFO_GROUP)
		return (erx_fiasco_service_call(ERX_FIASCO_CALL_OBJECT_INFO, &request, sizeof(request), &reply));
	if (erx_group_info(object) != ERX_OK)
		return (ERX_ENOTSUP);
	facts.group = erx_info_group_load(erx_utcb_self());
	return (erx_info_report(topic, index, &facts, window, size));
}
